#!/usr/bin/env bash
# post-upgrade.sh — Remove unwanted bundled Kimaki skills.
# Called by ExecStartPre in kimaki.service on each crew VPS.
set -euo pipefail

SKILLS_DIR="/usr/lib/node_modules/kimaki/skills"
KILL_LIST="$(dirname "$0")/skills-kill-list.txt"

if [[ ! -d "$SKILLS_DIR" ]]; then
  echo "kimaki-config: skills dir not found at $SKILLS_DIR, skipping"
  exit 0
fi

if [[ ! -f "$KILL_LIST" ]]; then
  echo "kimaki-config: kill list not found at $KILL_LIST, skipping"
  exit 0
fi

removed=0
while IFS= read -r skill || [[ -n "$skill" ]]; do
  # Skip comments and blank lines
  [[ -z "$skill" || "$skill" == \#* ]] && continue
  target="$SKILLS_DIR/$skill"
  if [[ -d "$target" ]]; then
    rm -rf "$target"
    echo "kimaki-config: removed $skill"
    removed=$((removed + 1))
  fi
done < "$KILL_LIST"

echo "kimaki-config: done ($removed skills removed)"
