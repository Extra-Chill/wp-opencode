#!/bin/bash
# Runtime: Claude Code — install, CLAUDE.md generation, .mcp.json merge

runtime_install() {
  log "Phase 7: Installing Claude Code..."

  if ! command -v claude &> /dev/null || [ "$DRY_RUN" = true ]; then
    run_cmd npm install -g @anthropic-ai/claude-code
  else
    log "Claude Code already installed: $(claude --version 2>/dev/null || echo 'unknown')"
  fi
}

runtime_discover_dm_paths() {
  log "Phase 7: Configuring Claude Code..."

  if ! command -v claude &> /dev/null && [ "$DRY_RUN" = false ]; then
    error "Claude Code not found after installation. Check PATH."
  fi

  DM_FILES=()
  if [ "$INSTALL_DATA_MACHINE" != true ]; then
    return
  fi

  if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/wp-config.php" ]; then
    AGENT_FLAG=""
    if [ -n "$AGENT_SLUG" ]; then
      AGENT_FLAG="--agent=$AGENT_SLUG"
    fi
    DM_PATHS_RAW=$(wp_cmd datamachine agent paths --format=json $AGENT_FLAG 2>/dev/null || echo "")
    # SQLite translation layer may emit HTML error noise — extract only JSON
    DM_PATHS_JSON=$(echo "$DM_PATHS_RAW" | sed -n '/^{/,/^}/p')
    if [ -n "$DM_PATHS_JSON" ]; then
      while IFS= read -r rel_path; do
        if [ -n "$rel_path" ]; then
          DM_FILES+=("$rel_path")
        fi
      done < <(echo "$DM_PATHS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for f in data.get('relative_files', []):
    print(f)
" 2>/dev/null)
      log "Agent files discovered via 'wp datamachine agent paths${AGENT_FLAG:+ ($AGENT_FLAG)}'"
    fi
  else
    # Dry-run: use placeholder paths
    DM_DRY_SLUG="${AGENT_SLUG:-AGENT_SLUG}"
    DM_FILES=(
      "wp-content/uploads/datamachine-files/shared/SITE.md"
      "wp-content/uploads/datamachine-files/shared/RULES.md"
      "wp-content/uploads/datamachine-files/agents/${DM_DRY_SLUG}/SOUL.md"
      "wp-content/uploads/datamachine-files/users/1/USER.md"
      "wp-content/uploads/datamachine-files/agents/${DM_DRY_SLUG}/MEMORY.md"
    )
    log "Dry-run: using placeholder agent paths (slug: $DM_DRY_SLUG)"
  fi

  # Fallback: check filesystem if CLI discovery failed
  if [ ${#DM_FILES[@]} -eq 0 ]; then
    log "Falling back to filesystem discovery..."
    DM_BASE="wp-content/uploads/datamachine-files"
    DM_SLUG="${AGENT_SLUG:-agent}"
    CANDIDATE_FILES=(
      "$DM_BASE/shared/SITE.md"
      "$DM_BASE/shared/RULES.md"
      "$DM_BASE/agents/$DM_SLUG/SOUL.md"
      "$DM_BASE/users/1/USER.md"
      "$DM_BASE/agents/$DM_SLUG/MEMORY.md"
    )
    for candidate in "${CANDIDATE_FILES[@]}"; do
      if [ -f "$SITE_PATH/$candidate" ]; then
        DM_FILES+=("$candidate")
      fi
    done
    log "Found ${#DM_FILES[@]} memory files on filesystem"
  fi
}

runtime_generate_config() {
  # Skip if already exists — may have been customized
  if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/CLAUDE.md" ]; then
    log "CLAUDE.md already exists — skipping (delete to regenerate)"
    return
  fi

  log "Generating CLAUDE.md..."

  TEMPLATE="$SCRIPT_DIR/workspace/CLAUDE.md.tmpl"
  if [ -f "$TEMPLATE" ]; then
    CLAUDE_MD=$(cat "$TEMPLATE")

    # Substitute placeholders
    CLAUDE_MD=$(echo "$CLAUDE_MD" | sed "s|{{SITE_DOMAIN}}|$SITE_DOMAIN|g")
    WP_CLI_DISPLAY="wp"
    if [ "$IS_STUDIO" = true ]; then
      WP_CLI_DISPLAY="studio wp"
    elif [ "$LOCAL_MODE" = false ]; then
      WP_CLI_DISPLAY="wp $WP_ROOT_FLAG --path=$SITE_PATH"
    fi
    CLAUDE_MD=$(echo "$CLAUDE_MD" | sed "s|{{WP_CLI_CMD}}|$WP_CLI_DISPLAY|g")

    # Process Studio conditional
    if [ "$IS_STUDIO" = true ]; then
      CLAUDE_MD=$(echo "$CLAUDE_MD" | sed '/{{IF_STUDIO}}/d; /{{END_IF_STUDIO}}/d')
    else
      CLAUDE_MD=$(echo "$CLAUDE_MD" | sed '/{{IF_STUDIO}}/,/{{END_IF_STUDIO}}/d')
    fi

    # Process Data Machine conditional
    if [ "$INSTALL_DATA_MACHINE" = true ]; then
      CLAUDE_MD=$(echo "$CLAUDE_MD" | sed '/{{IF_DATA_MACHINE}}/d; /{{END_IF_DATA_MACHINE}}/d')
      CLAUDE_MD=$(echo "$CLAUDE_MD" | sed '/{{IF_NO_DATA_MACHINE}}/,/{{END_IF_NO_DATA_MACHINE}}/d')

      # Build @ includes from discovered files and wrap with sentinels
      AT_INCLUDES=""
      for dm_file in "${DM_FILES[@]}"; do
        AT_INCLUDES="${AT_INCLUDES}@${dm_file}
"
      done

      DISCOVER_LINE="Discover DM paths: \`$WP_CLI_DISPLAY datamachine agent paths\`"
      SENTINEL_CONTENT="<!-- DM_AGENT_SYNC_START -->
${AT_INCLUDES}
${DISCOVER_LINE}
<!-- DM_AGENT_SYNC_END -->"

      CLAUDE_MD=$(python3 -c "
import sys
content = sys.argv[1]
block = sys.argv[2]
start = '<!-- DM_AGENT_SYNC_START -->'
end = '<!-- DM_AGENT_SYNC_END -->'
si = content.index(start)
ei = content.index(end) + len(end)
print(content[:si] + block + content[ei:], end='')
" "$CLAUDE_MD" "$SENTINEL_CONTENT")
    else
      CLAUDE_MD=$(echo "$CLAUDE_MD" | sed '/{{IF_DATA_MACHINE}}/,/{{END_IF_DATA_MACHINE}}/d')
      CLAUDE_MD=$(echo "$CLAUDE_MD" | sed '/{{IF_NO_DATA_MACHINE}}/d; /{{END_IF_NO_DATA_MACHINE}}/d')
    fi

    # Process Multisite conditional
    if [ "$MULTISITE" = true ]; then
      CLAUDE_MD=$(echo "$CLAUDE_MD" | sed '/{{IF_MULTISITE}}/d; /{{END_IF_MULTISITE}}/d')
    else
      CLAUDE_MD=$(echo "$CLAUDE_MD" | sed '/{{IF_MULTISITE}}/,/{{END_IF_MULTISITE}}/d')
    fi

    # Clean up stacked empty lines from conditional removal
    CLAUDE_MD=$(echo "$CLAUDE_MD" | sed '/^$/N;/^\n$/d')

    write_file "$SITE_PATH/CLAUDE.md" "$CLAUDE_MD"
    log "Generated CLAUDE.md at $SITE_PATH/CLAUDE.md"
  else
    # Inline generation if template not found
    warn "Template not found at $TEMPLATE — generating inline"

    WP_CLI_DISPLAY="wp"
    if [ "$IS_STUDIO" = true ]; then
      WP_CLI_DISPLAY="studio wp"
    elif [ "$LOCAL_MODE" = false ]; then
      WP_CLI_DISPLAY="wp $WP_ROOT_FLAG --path=$SITE_PATH"
    fi

    CLAUDE_CONTENT="# $SITE_DOMAIN

WP-CLI: \`$WP_CLI_DISPLAY\`"

    if [ "$IS_STUDIO" = true ]; then
      CLAUDE_CONTENT="$CLAUDE_CONTENT

@STUDIO.md"
    fi

    CLAUDE_CONTENT="$CLAUDE_CONTENT

## Data Machine Memory"

    if [ "$INSTALL_DATA_MACHINE" = true ]; then
      CLAUDE_CONTENT="$CLAUDE_CONTENT

<!-- DM_AGENT_SYNC_START -->"
      for dm_file in "${DM_FILES[@]}"; do
        CLAUDE_CONTENT="$CLAUDE_CONTENT
@$dm_file"
      done

      CLAUDE_CONTENT="$CLAUDE_CONTENT

Discover DM paths: \`$WP_CLI_DISPLAY datamachine agent paths\`
<!-- DM_AGENT_SYNC_END -->"
    else
      CLAUDE_CONTENT="$CLAUDE_CONTENT

Data Machine not installed."
    fi

    CLAUDE_CONTENT="$CLAUDE_CONTENT

## WordPress Source

- \`wp-content/plugins/\` — all plugin source
- \`wp-content/themes/\` — all theme source
- \`wp-includes/\` — WordPress core (read-only)"

    if [ "$MULTISITE" = true ]; then
      CLAUDE_CONTENT="$CLAUDE_CONTENT

## Multisite

This is a WordPress Multisite network. Use \`--url=<site>\` with WP-CLI commands to target a specific site."
    fi

    CLAUDE_CONTENT="$CLAUDE_CONTENT

## Memory Protocol

Update MEMORY.md when you learn something persistent — read it first, append.

## Rules

- Discover before memorizing — use \`--help\`
- Don't deploy or version bump without being told
- Never modify wp-includes/ or wp-admin/"

    write_file "$SITE_PATH/CLAUDE.md" "$CLAUDE_CONTENT"
    log "Generated CLAUDE.md at $SITE_PATH/CLAUDE.md (inline)"
  fi
}

runtime_install_hooks() {
  if [ "$INSTALL_DATA_MACHINE" != true ]; then
    return
  fi

  log "Installing Claude Code SessionStart hook..."

  local hooks_dir="$SITE_PATH/.claude/hooks"
  local hook_src="$SCRIPT_DIR/hooks/dm-agent-sync.sh"
  local hook_dst="$hooks_dir/dm-agent-sync.sh"
  local settings_file="$SITE_PATH/.claude/settings.json"

  if [ ! -f "$hook_src" ]; then
    warn "Hook source not found at $hook_src — skipping"
    return
  fi

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would copy dm-agent-sync.sh to $hooks_dir"
    echo -e "${BLUE}[dry-run]${NC} Would configure SessionStart hook in $settings_file"
    return
  fi

  mkdir -p "$hooks_dir"
  cp "$hook_src" "$hook_dst"
  chmod +x "$hook_dst"
  log "Installed hook: $hook_dst"

  # Merge SessionStart hook and disable auto-memory in settings.json
  local hook_cmd="\"\$CLAUDE_PROJECT_DIR\"/.claude/hooks/dm-agent-sync.sh"

  python3 -c "
import json, sys, os

settings_path = sys.argv[1]
hook_cmd = sys.argv[2]

settings = {}
if os.path.isfile(settings_path):
    with open(settings_path) as f:
        settings = json.load(f)

# Disable built-in auto-memory (conflicts with Data Machine MEMORY.md)
settings['autoMemoryEnabled'] = False

# Register SessionStart hook (idempotent)
hooks = settings.setdefault('hooks', {})
session_hooks = hooks.setdefault('SessionStart', [])

already_registered = any(
    (isinstance(h, str) and h == hook_cmd) or
    (isinstance(h, dict) and h.get('command') == hook_cmd)
    for h in session_hooks
)

if not already_registered:
    session_hooks.append({'command': hook_cmd})

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
" "$settings_file" "$hook_cmd"

  log "Configured settings.json: SessionStart hook + autoMemoryEnabled=false"
}

runtime_generate_instructions() {
  # Claude Code uses CLAUDE.md as the instructions file — no separate step needed
  return
}

runtime_merge_mcp_servers() {
  if [ -z "${MCP_SERVERS:-}" ]; then
    return
  fi

  local mcp_file="$SITE_PATH/.mcp.json"

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would merge MCP_SERVERS into $mcp_file"
    return
  fi

  command -v jq &>/dev/null || error "MCP_SERVERS requires jq"
  log "Merging MCP servers into .mcp.json..."

  if [ -f "$mcp_file" ]; then
    jq --argjson servers "$MCP_SERVERS" '.mcpServers = (.mcpServers // {} | . * $servers)' "$mcp_file" \
      > "${mcp_file}.tmp" \
      && mv "${mcp_file}.tmp" "$mcp_file"
  else
    jq -n --argjson servers "$MCP_SERVERS" '{"mcpServers": $servers}' > "$mcp_file"
  fi
}

runtime_skills_dir() {
  echo "$SITE_PATH/.claude/skills"
}

runtime_print_summary() {
  echo "Claude Code:"
  echo "  Config:   $SITE_PATH/CLAUDE.md"
  if [ ${#DM_FILES[@]} -gt 0 ]; then
    echo "  Includes: ${#DM_FILES[@]} Data Machine @ includes"
  fi
  echo ""
}
