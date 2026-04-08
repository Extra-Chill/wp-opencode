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

      # Remove per-file conditionals (we insert actual discovered paths instead)
      CLAUDE_MD=$(echo "$CLAUDE_MD" | sed '/{{IF_SITE_MD}}/,/{{END_IF_SITE_MD}}/d')
      CLAUDE_MD=$(echo "$CLAUDE_MD" | sed '/{{IF_RULES_MD}}/,/{{END_IF_RULES_MD}}/d')
      CLAUDE_MD=$(echo "$CLAUDE_MD" | sed '/{{IF_SOUL_MD}}/,/{{END_IF_SOUL_MD}}/d')
      CLAUDE_MD=$(echo "$CLAUDE_MD" | sed '/{{IF_USER_MD}}/,/{{END_IF_USER_MD}}/d')
      CLAUDE_MD=$(echo "$CLAUDE_MD" | sed '/{{IF_MEMORY_MD}}/,/{{END_IF_MEMORY_MD}}/d')

      # Build @ includes from discovered files
      AT_INCLUDES=""
      for dm_file in "${DM_FILES[@]}"; do
        AT_INCLUDES="${AT_INCLUDES}@${dm_file}
"
      done

      if [ -n "$AT_INCLUDES" ]; then
        CLAUDE_MD="${CLAUDE_MD/## Data Machine Memory/## Data Machine Memory

$AT_INCLUDES}"
      fi
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
      for dm_file in "${DM_FILES[@]}"; do
        CLAUDE_CONTENT="$CLAUDE_CONTENT
@$dm_file"
      done

      CLAUDE_CONTENT="$CLAUDE_CONTENT

Discover DM paths: \`$WP_CLI_DISPLAY datamachine agent paths\`"
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
