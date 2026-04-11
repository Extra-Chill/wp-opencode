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
  if [ ! -f "$TEMPLATE" ]; then
    error "CLAUDE.md template not found at $TEMPLATE"
  fi

  CLAUDE_MD=$(cat "$TEMPLATE")

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

  # Clean up stacked empty lines from conditional removal
  CLAUDE_MD=$(echo "$CLAUDE_MD" | sed '/^$/N;/^\n$/d')

  write_file "$SITE_PATH/CLAUDE.md" "$CLAUDE_MD"
  log "Generated CLAUDE.md at $SITE_PATH/CLAUDE.md"
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

  # Merge SessionStart hook, workspace permissions, and disable auto-memory in settings.json
  local hook_cmd="\"\$CLAUDE_PROJECT_DIR\"/.claude/hooks/dm-agent-sync.sh"

  python3 -c "
import json, sys, os

settings_path = sys.argv[1]
hook_cmd = sys.argv[2]
workspace_dir = sys.argv[3]

settings = {}
if os.path.isfile(settings_path):
    with open(settings_path) as f:
        settings = json.load(f)

# Disable built-in auto-memory (conflicts with Data Machine MEMORY.md)
settings['autoMemoryEnabled'] = False

# Allow DM workspace as additional directory (read/write without prompting)
perms = settings.setdefault('permissions', {})
additional_dirs = perms.setdefault('additionalDirectories', [])
if workspace_dir not in additional_dirs:
    additional_dirs.append(workspace_dir)

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
" "$settings_file" "$hook_cmd" "$DM_WORKSPACE_DIR"

  log "Configured settings.json: SessionStart hook, workspace permissions, autoMemoryEnabled=false"
}

runtime_generate_instructions() {
  if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/AGENTS.md" ]; then
    log "AGENTS.md already exists — skipping (delete to regenerate)"
    return
  fi

  log "Generating AGENTS.md..."

  local agents_tmpl="$SCRIPT_DIR/workspace/AGENTS.md"
  if [ ! -f "$agents_tmpl" ]; then
    error "AGENTS.md template not found at $agents_tmpl"
  fi

  WP_CLI_DISPLAY="wp"
  if [ "$IS_STUDIO" = true ]; then
    WP_CLI_DISPLAY="studio wp"
  elif [ "$LOCAL_MODE" = false ]; then
    WP_CLI_DISPLAY="wp $WP_ROOT_FLAG --path=$SITE_PATH"
  fi

  local agents_md
  agents_md=$(sed "s|{{WP_CLI_CMD}}|$WP_CLI_DISPLAY|g" "$agents_tmpl")

  # Remove Data Machine sections if DM not installed
  if [ "$INSTALL_DATA_MACHINE" = false ]; then
    agents_md=$(echo "$agents_md" | awk '/^### (Data Machine|Workspace)/{skip=1; next} /^### /{skip=0} /^## /{skip=0} !skip')
  fi

  # Remove multisite section for single-site installs
  if [ "$MULTISITE" != true ]; then
    agents_md=$(echo "$agents_md" | awk '/^### Multisite/{skip=1; next} /^### /{skip=0} /^## /{skip=0} !skip')
  fi

  write_file "$SITE_PATH/AGENTS.md" "$agents_md"
  log "Generated AGENTS.md at $SITE_PATH/AGENTS.md"
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
