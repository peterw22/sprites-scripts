#!/usr/bin/env bash
# Rolls a workspace back to the "clean" checkpoint made by new-workspace.sh.
# Everything changed since then is discarded.
# Usage: ./reset-workspace.sh <name>
set -euo pipefail
name="${1:?usage: reset-workspace.sh <name>}"

id="$(sprite checkpoint list -s "$name" | awk '$NF == "clean" { print $1; exit }')"
if [ -z "$id" ]; then
  echo "No checkpoint with comment \"clean\" on $name" >&2
  exit 1
fi

sprite restore -s "$name" "$id"

pass_file="$HOME/.config/sprites/$name.pass"
if [ -f "$pass_file" ]; then
  printf 'sprite:%s\n' "$(<"$pass_file")" | sprite exec -s "$name" -- sudo chpasswd
fi
