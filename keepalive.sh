#!/usr/bin/env bash
# Keeps a Sprite awake in the background for a bounded duration (max 8 hours).
# Never runs indefinitely, so a forgotten Sprite cannot bill forever.
#
# Usage:
#   ./keepalive.sh <sprite-name> [duration]   # e.g. 30m, 2h, 8h (default: 1h, max: 8h)
#   ./keepalive.sh <sprite-name> status       # show active keepalive status
#   ./keepalive.sh <sprite-name> off          # cancel keepalive and let Sprite sleep
set -euo pipefail

name="${1:?usage: keepalive.sh <sprite-name> [duration|status|off] (max 8h)}"
action="${2:-1h}"
max_seconds=$((8 * 3600))

parse_duration() {
  local input="$1"
  if [[ "$input" =~ ^([0-9]+)h$ ]]; then
    echo $(( BASH_REMATCH[1] * 3600 ))
  elif [[ "$input" =~ ^([0-9]+)m$ ]]; then
    echo $(( BASH_REMATCH[1] * 60 ))
  elif [[ "$input" =~ ^([0-9]+)s?$ ]]; then
    echo $(( BASH_REMATCH[1] ))
  else
    return 1
  fi
}

case "$action" in
  off|stop|cancel)
    sprite exec -s "$name" -- bash -c '
      if [ -f /tmp/sprite-keepalive.pid ]; then
        kill "$(cat /tmp/sprite-keepalive.pid)" 2>/dev/null || true
        rm -f /tmp/sprite-keepalive.pid /tmp/sprite-keepalive.until
      fi
      pkill -f "sprite-keepalive-worker" 2>/dev/null || true
      sprite-env curl -s -X DELETE /v1/tasks/keepalive >/dev/null 2>&1 || true
    '
    echo "Keepalive stopped on '$name'. Sprite will pause when idle."
    ;;

  status)
    sprite exec -s "$name" -- bash -c '
      if [ -f /tmp/sprite-keepalive.until ]; then
        until_ts="$(cat /tmp/sprite-keepalive.until)"
        now_ts="$(date +%s)"
        rem=$(( until_ts - now_ts ))
        if [ "$rem" -gt 0 ]; then
          printf "Keepalive active: %dh %dm %ds remaining (until %s UTC)\n" \
            $((rem/3600)) $(((rem%3600)/60)) $((rem%60)) \
            "$(date -u -d "@$until_ts" "+%Y-%m-%d %H:%M:%S")"
        else
          echo "Keepalive loop finished."
        fi
      else
        echo "No multi-hour keepalive timer recorded."
      fi
      echo -n "Tasks API state: "
      sprite-env curl -s /v1/tasks
      echo
    '
    ;;

  *)
    if ! seconds="$(parse_duration "$action")" || [ "$seconds" -le 0 ]; then
      echo "Error: invalid duration '$action'. Use e.g. 30m, 2h, 8h, 'status', or 'off'." >&2
      exit 1
    fi
    if [ "$seconds" -gt "$max_seconds" ]; then
      echo "Error: requested duration ($action) exceeds the 8h maximum." >&2
      exit 1
    fi

    sprite exec -s "$name" --env "DURATION_SEC=$seconds" -- bash -c '
      set -e
      # Stop any existing keepalive worker first
      if [ -f /tmp/sprite-keepalive.pid ]; then
        kill "$(cat /tmp/sprite-keepalive.pid)" 2>/dev/null || true
        rm -f /tmp/sprite-keepalive.pid /tmp/sprite-keepalive.until
      fi
      pkill -f "sprite-keepalive-worker" 2>/dev/null || true

      until_ts=$(( $(date +%s) + DURATION_SEC ))
      echo "$until_ts" > /tmp/sprite-keepalive.until

      # Acquire initial lease immediately before backgrounding so the Sprite
      # cannot pause right as `sprite exec` disconnects.
      first_lease=$(( DURATION_SEC < 300 ? DURATION_SEC : 300 ))
      sprite-env curl -s -X PUT /v1/tasks/keepalive \
        -H "Content-Type: application/json" \
        -d "{\"expire\":\"${first_lease}s\"}" >/dev/null

      nohup bash -c "
        # tag for pkill: sprite-keepalive-worker
        trap \"sprite-env curl -s -X DELETE /v1/tasks/keepalive >/dev/null 2>&1 || true; rm -f /tmp/sprite-keepalive.pid /tmp/sprite-keepalive.until\" EXIT
        while true; do
          now=\$(date +%s)
          rem=\$(( $until_ts - now ))
          if [ \"\$rem\" -le 0 ]; then
            break
          fi
          lease=\$(( rem < 300 ? rem : 300 ))
          sprite-env curl -s -X PUT /v1/tasks/keepalive \
            -H \"Content-Type: application/json\" \
            -d \"{\\\"expire\\\":\\\"\${lease}s\\\"}\" >/dev/null
          sleep_sec=\$(( rem < 60 ? rem : 60 ))
          sleep \"\$sleep_sec\"
        done
      " >/dev/null 2>&1 < /dev/null &
      echo $! > /tmp/sprite-keepalive.pid
    '

    hours=$(( seconds / 3600 ))
    mins=$(( (seconds % 3600) / 60 ))
    echo "Keepalive set on '$name' for ${action} (${hours}h ${mins}m, hard-capped at 8h max)."
    echo "  Check status: ./keepalive.sh $name status"
    echo "  Stop early:   ./keepalive.sh $name off"
    ;;
esac
