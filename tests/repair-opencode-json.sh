#!/bin/bash
# tests/repair-opencode-json.sh — regression tests for opencode.json repair.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPAIR="$SCRIPT_DIR/lib/repair-opencode-json.py"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

assert_json_missing_agent_slots() {
  python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

agent = data.get("agent", {})
if "build" in agent or "plan" in agent:
    raise SystemExit(f"managed build/plan slots should be removed: {agent}")
PY
}

cat > "$TMP/default-only.json" <<'JSON'
{
  "model": "anthropic/claude-opus-4-7",
  "agent": {
    "build": { "mode": "primary", "model": "anthropic/claude-opus-4-7" },
    "plan": { "mode": "primary", "model": "anthropic/claude-opus-4-7" }
  }
}
JSON

python3 "$REPAIR" \
  --file "$TMP/default-only.json" \
  --runtime opencode \
  --chat-bridge kimaki \
  --kimaki-plugins-dir /opt/kimaki-config/plugins \
  --additive > "$TMP/default-only.out"

assert_json_missing_agent_slots "$TMP/default-only.json"
grep -q '"agent_cleanup": "removed"' "$TMP/default-only.out"

cat > "$TMP/prompt-migration.json" <<'JSON'
{
  "model": "anthropic/claude-opus-4-7",
  "agent": {
    "build": {
      "mode": "primary",
      "model": "anthropic/claude-opus-4-7",
      "prompt": "{file:./AGENTS.md}\n{file:./SOUL.md}\n{file:./MEMORY.md}"
    },
    "plan": {
      "mode": "primary",
      "model": "anthropic/claude-opus-4-7",
      "prompt": "{file:./AGENTS.md}\n{file:./SOUL.md}"
    }
  }
}
JSON

python3 "$REPAIR" \
  --file "$TMP/prompt-migration.json" \
  --runtime opencode \
  --chat-bridge kimaki \
  --kimaki-plugins-dir /opt/kimaki-config/plugins \
  --additive > "$TMP/prompt-migration.out"

assert_json_missing_agent_slots "$TMP/prompt-migration.json"
python3 - "$TMP/prompt-migration.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

if data.get("instructions") != ["./SOUL.md", "./MEMORY.md"]:
    raise SystemExit(f"unexpected instructions: {data.get('instructions')}")
PY

cat > "$TMP/custom-agent.json" <<'JSON'
{
  "model": "anthropic/claude-opus-4-7",
  "agent": {
    "build": { "mode": "primary", "tools": { "bash": true } },
    "plan": { "mode": "primary", "model": "openai/gpt-5.5" }
  }
}
JSON

python3 "$REPAIR" \
  --file "$TMP/custom-agent.json" \
  --runtime opencode \
  --chat-bridge kimaki \
  --kimaki-plugins-dir /opt/kimaki-config/plugins \
  --additive > "$TMP/custom-agent.out"

python3 - "$TMP/custom-agent.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

agent = data.get("agent", {})
if "build" not in agent or "plan" not in agent:
    raise SystemExit(f"custom build/plan slots should be preserved: {agent}")
PY

echo "OK: repair-opencode-json removes managed agent shells"
