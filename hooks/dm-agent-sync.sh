#!/bin/bash
# dm-agent-sync.sh — Claude Code SessionStart hook
#
# Runs before every Claude Code session. Queries Data Machine for all active
# agents and their files, then updates CLAUDE.md with current @ includes.
# New agents created after setup are automatically discovered.
#
# Installed to: $SITE_PATH/.claude/hooks/dm-agent-sync.sh
# Triggered by: Claude Code SessionStart hook

set -euo pipefail

SITE_PATH="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$SITE_PATH" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Detect WP-CLI command
# ---------------------------------------------------------------------------

detect_wp_cmd() {
  if [ -f "$SITE_PATH/STUDIO.md" ] && command -v studio &>/dev/null; then
    echo "studio wp"
    return
  fi

  if ! command -v wp &>/dev/null; then
    return 1
  fi

  local cmd="wp --path=$SITE_PATH"
  if [ "$(id -u)" -eq 0 ]; then
    cmd="$cmd --allow-root"
  fi
  echo "$cmd"
}

WP_CMD=$(detect_wp_cmd) || exit 0

# ---------------------------------------------------------------------------
# Query active agents from Data Machine
# ---------------------------------------------------------------------------

AGENTS_RAW=$($WP_CMD datamachine agents list --format=json 2>/dev/null) || exit 0

# Extract JSON array (wp may append summary text after the array)
AGENTS_JSON=$(echo "$AGENTS_RAW" | sed -n '/^\[/,/^\]/p')
if [ -z "$AGENTS_JSON" ]; then
  exit 0
fi

# Parse active agent slugs
ACTIVE_SLUGS=$(echo "$AGENTS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for a in data:
    if a.get('status') == 'active':
        print(a['agent_slug'])
" 2>/dev/null) || exit 0

if [ -z "$ACTIVE_SLUGS" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Collect files from all active agents, deduplicating shared files
# ---------------------------------------------------------------------------

ALL_FILES=""
while IFS= read -r slug; do
  PATHS_RAW=$($WP_CMD datamachine agent paths --agent="$slug" --format=json 2>/dev/null) || continue
  PATHS_JSON=$(echo "$PATHS_RAW" | sed -n '/^{/,/^}/p')
  [ -z "$PATHS_JSON" ] && continue

  FILES=$(echo "$PATHS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for f in data.get('relative_files', []):
    print(f)
" 2>/dev/null) || continue

  if [ -n "$FILES" ]; then
    ALL_FILES="${ALL_FILES}${ALL_FILES:+
}${FILES}"
  fi
done <<< "$ACTIVE_SLUGS"

if [ -z "$ALL_FILES" ]; then
  exit 0
fi

# Deduplicate while preserving order
UNIQUE_FILES=$(echo "$ALL_FILES" | awk '!seen[$0]++')

# Build @ includes block
AT_INCLUDES=""
while IFS= read -r f; do
  AT_INCLUDES="${AT_INCLUDES}@${f}
"
done <<< "$UNIQUE_FILES"

DISCOVER_LINE="Discover DM paths: \`$WP_CMD datamachine agent paths\`"
NEW_CONTENT="${AT_INCLUDES}
${DISCOVER_LINE}"

# ---------------------------------------------------------------------------
# Update CLAUDE.md between sentinels
# ---------------------------------------------------------------------------

CLAUDE_MD_PATH="$SITE_PATH/CLAUDE.md"

if [ ! -f "$CLAUDE_MD_PATH" ]; then
  # No CLAUDE.md — create minimal version with sentinels
  cat > "$CLAUDE_MD_PATH" << MINEOF
# $(basename "$SITE_PATH")

## Data Machine Memory

<!-- DM_AGENT_SYNC_START -->
${NEW_CONTENT}
<!-- DM_AGENT_SYNC_END -->

## Memory Protocol

Update MEMORY.md when you learn something persistent — read it first, append.
MINEOF
  exit 0
fi

EXISTING=$(cat "$CLAUDE_MD_PATH")

# Try sentinel-based replacement first
if echo "$EXISTING" | grep -q '<!-- DM_AGENT_SYNC_START -->'; then
  python3 -c "
import sys

content = sys.stdin.read()
new_block = sys.argv[1]
start_sentinel = '<!-- DM_AGENT_SYNC_START -->'
end_sentinel = '<!-- DM_AGENT_SYNC_END -->'

start_idx = content.index(start_sentinel) + len(start_sentinel)
end_idx = content.index(end_sentinel)

updated = content[:start_idx] + '\n' + new_block + '\n' + content[end_idx:]
sys.stdout.write(updated)
" "$NEW_CONTENT" <<< "$EXISTING" > "$CLAUDE_MD_PATH"
  exit 0
fi

# Fallback: heading-based replacement for pre-upgrade CLAUDE.md files
if echo "$EXISTING" | grep -q '## Data Machine Memory'; then
  python3 -c "
import sys, re

content = sys.stdin.read()
new_block = sys.argv[1]

pattern = r'(## Data Machine Memory\n).*?(?=\n## |\Z)'
replacement = r'\g<1>\n<!-- DM_AGENT_SYNC_START -->\n' + new_block.replace('\\\\', '\\\\\\\\') + r'\n<!-- DM_AGENT_SYNC_END -->'
updated = re.sub(pattern, replacement, content, count=1, flags=re.DOTALL)
sys.stdout.write(updated)
" "$NEW_CONTENT" <<< "$EXISTING" > "$CLAUDE_MD_PATH"
  exit 0
fi

# No heading found — append DM section
cat >> "$CLAUDE_MD_PATH" << APPENDEOF

## Data Machine Memory

<!-- DM_AGENT_SYNC_START -->
${NEW_CONTENT}
<!-- DM_AGENT_SYNC_END -->
APPENDEOF
