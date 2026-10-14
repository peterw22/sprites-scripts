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
      rm -f ~/.local/state/sprite-keepalive.until
      sprite-env services delete keepalive >/dev/null 2>&1 || true
      sprite-env curl -s -X DELETE /v1/tasks/keepalive >/dev/null 2>&1 || true
    '
    echo "Keepalive stopped on '$name'. Sprite will pause when idle."
    ;;

  status)
    sprite exec -s "$name" -- bash -c '
      if [ -f ~/.local/state/sprite-keepalive.until ]; then
        until_ts="$(cat ~/.local/state/sprite-keepalive.until)"
        now_ts="$(date +%s)"
        rem=$(( until_ts - now_ts ))
        if [ "$rem" -gt 0 ]; then
          printf "Keepalive active: %dh %dm %ds remaining (until %s UTC)\n" \
            $((rem/3600)) $(((rem%3600)/60)) $((rem%60)) \
            "$(date -u -d "@$until_ts" "+%Y-%m-%d %H:%M:%S")"
        else
          echo "Keepalive timer expired."
        fi
      else
        echo "No active keepalive timer."
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

    # Note: `sprite exec` kills its child process group on exit, so the worker
    # MUST run as a Sprite service (`sprite-env services`) rather than `nohup &`.
    sprite exec -s "$name" --env "DURATION_SEC=$seconds" -- bash -c '
      set -e
      install -d -m700 ~/.local/bin ~/.local/state
      until_ts=$(( $(date +%s) + DURATION_SEC ))
      echo "$until_ts" > ~/.local/state/sprite-keepalive.until

      cat << "EOF" > ~/.local/bin/sprite-keepalive-worker
#!/usr/bin/env bash
set -u
until_file="$HOME/.local/state/sprite-keepalive.until"

while true; do
  if [ ! -f "$until_file" ]; then
    break
  fi
  until_ts="$(cat "$until_file" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  rem=$(( until_ts - now ))
  if [ "$rem" -le 0 ]; then
    rm -f "$until_file"
    break
  fi
  # Tasks API max lease is 1h (3600s); use up to 5m (300s) and refresh every 60s.
  lease=$(( rem < 300 ? rem : 300 ))
  sprite-env curl -s -X PUT /v1/tasks/keepalive \
    -H "Content-Type: application/json" \
    -d "{\"expire\":\"${lease}s\"}" >/dev/null 2>&1 || true
  sleep_sec=$(( rem < 60 ? rem : 60 ))
  sleep "$sleep_sec"
done

sprite-env curl -s -X DELETE /v1/tasks/keepalive >/dev/null 2>&1 || true
sprite-env services delete keepalive >/dev/null 2>&1 || true
EOF
      chmod +x ~/.local/bin/sprite-keepalive-worker

      # Acquire initial lease synchronously right now so the Sprite stays awake
      # while the service spins up.
      first_lease=$(( DURATION_SEC < 300 ? DURATION_SEC : 300 ))
      sprite-env curl -s -X PUT /v1/tasks/keepalive \
        -H "Content-Type: application/json" \
        -d "{\"expire\":\"${first_lease}s\"}" >/dev/null

      sprite-env services delete keepalive >/dev/null 2>&1 || true
      sprite-env services create keepalive \
        --cmd "$HOME/.local/bin/sprite-keepalive-worker" \
        --no-stream >/dev/null
    '

    hours=$(( seconds / 3600 ))
    mins=$(( (seconds % 3600) / 60 ))
    echo "Keepalive set on '$name' for ${action} (${hours}h ${mins}m, hard-capped at 8h max)."
    echo "  Check status: ./keepalive.sh $name status"
    echo "  Stop early:   ./keepalive.sh $name off"
    ;;
esac
