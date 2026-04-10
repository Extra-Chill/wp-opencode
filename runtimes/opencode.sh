#!/bin/bash
# Runtime: OpenCode — install, config generation, AGENTS.md, MCP merge

runtime_install() {
  log "Phase 7: Installing OpenCode..."

  if ! command -v opencode &> /dev/null || [ "$DRY_RUN" = true ]; then
    run_cmd npm install -g opencode-ai
  else
    log "OpenCode already installed: $(opencode --version 2>/dev/null || echo 'unknown')"
  fi
}

runtime_discover_dm_paths() {
  if [ "$INSTALL_DATA_MACHINE" != true ]; then
    OPENCODE_PROMPT='{file:./AGENTS.md}'
    return
  fi

  if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/wp-config.php" ]; then
    AGENT_FLAG=""
    if [ -n "$AGENT_SLUG" ]; then
      AGENT_FLAG="--agent=$AGENT_SLUG"
    fi
    DM_PATHS_RAW=$($WP_CMD datamachine agent paths --format=json $AGENT_FLAG $WP_ROOT_FLAG --path="$SITE_PATH" 2>/dev/null)
    # SQLite translation layer may emit HTML error noise — extract only JSON
    DM_PATHS_JSON=$(echo "$DM_PATHS_RAW" | sed -n '/^{/,/^}/p')
    if [ -z "$DM_PATHS_JSON" ]; then
      error "'$WP_CMD datamachine agent paths' returned no JSON — is Data Machine active and agent created?"
    fi
    DM_AGENT_FILES=$(echo "$DM_PATHS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for f in data.get('relative_files', []):
    print(f)
")
    log "Agent files discovered via '$WP_CMD datamachine agent paths${AGENT_FLAG:+ ($AGENT_FLAG)}'"
  else
    # Dry-run: use placeholder paths
    DM_DRY_SLUG="${AGENT_SLUG:-AGENT_SLUG}"
    DM_AGENT_FILES="wp-content/uploads/datamachine-files/shared/SITE.md
wp-content/uploads/datamachine-files/agents/${DM_DRY_SLUG}/SOUL.md
wp-content/uploads/datamachine-files/agents/${DM_DRY_SLUG}/MEMORY.md
wp-content/uploads/datamachine-files/users/USER_ID/USER.md"
    log "Dry-run: using placeholder agent paths (slug: $DM_DRY_SLUG)"
  fi

  # Build prompt from discovered files
  OPENCODE_PROMPT="{file:./AGENTS.md}"
  while IFS= read -r rel_path; do
    OPENCODE_PROMPT="$OPENCODE_PROMPT\\\\n{file:./${rel_path}}"
  done <<< "$DM_AGENT_FILES"
}

runtime_generate_config() {
  # Skip if already exists — safe for re-runs
  if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/opencode.json" ]; then
    log "opencode.json already exists — skipping (delete to regenerate)"
    return
  fi

  log "Generating opencode.json..."

  OPENCODE_JSON="{"
  OPENCODE_JSON="$OPENCODE_JSON\n  \"\$schema\": \"https://opencode.ai/config.json\""

  if [ -n "$OPENCODE_MODEL" ]; then
    OPENCODE_JSON="$OPENCODE_JSON,\n  \"model\": \"${OPENCODE_MODEL}\""
  fi
  if [ -n "$OPENCODE_SMALL_MODEL" ]; then
    OPENCODE_JSON="$OPENCODE_JSON,\n  \"small_model\": \"${OPENCODE_SMALL_MODEL}\""
  fi

  # OpenCode plugins — only when DM handles memory/scheduling via Kimaki
  if [ "$INSTALL_DATA_MACHINE" = true ] && [ "$CHAT_BRIDGE" = "kimaki" ]; then
    if [ "$LOCAL_MODE" = true ]; then
      KIMAKI_PLUGINS_DIR="$(npm root -g 2>/dev/null)/kimaki/plugins"
      if [ "$DRY_RUN" = false ] && [ -d "$(dirname "$KIMAKI_PLUGINS_DIR")" ]; then
        mkdir -p "$KIMAKI_PLUGINS_DIR"
        cp "$SCRIPT_DIR/kimaki/plugins/dm-context-filter.ts" "$KIMAKI_PLUGINS_DIR/" 2>/dev/null || true
        cp "$SCRIPT_DIR/kimaki/plugins/dm-agent-sync.ts" "$KIMAKI_PLUGINS_DIR/" 2>/dev/null || true
      fi
    else
      KIMAKI_PLUGINS_DIR="/opt/kimaki-config/plugins"
    fi
    OPENCODE_JSON="$OPENCODE_JSON,\n  \"plugin\": ["
    OPENCODE_JSON="$OPENCODE_JSON\n    \"${KIMAKI_PLUGINS_DIR}/dm-context-filter.ts\","
    OPENCODE_JSON="$OPENCODE_JSON\n    \"${KIMAKI_PLUGINS_DIR}/dm-agent-sync.ts\""
    OPENCODE_JSON="$OPENCODE_JSON\n  ]"
  fi

  # Agent prompt config
  OPENCODE_JSON="$OPENCODE_JSON,\n  \"agent\": {"
  OPENCODE_JSON="$OPENCODE_JSON\n    \"build\": {"
  OPENCODE_JSON="$OPENCODE_JSON\n      \"prompt\": \"${OPENCODE_PROMPT}\""
  OPENCODE_JSON="$OPENCODE_JSON\n    },"
  OPENCODE_JSON="$OPENCODE_JSON\n    \"plan\": {"
  OPENCODE_JSON="$OPENCODE_JSON\n      \"prompt\": \"${OPENCODE_PROMPT}\""
  OPENCODE_JSON="$OPENCODE_JSON\n    }"
  OPENCODE_JSON="$OPENCODE_JSON\n  }"

  # Permission: allow DM workspace as external directory
  if [ "$INSTALL_DATA_MACHINE" = true ]; then
    OPENCODE_JSON="$OPENCODE_JSON,\n  \"permission\": {"
    OPENCODE_JSON="$OPENCODE_JSON\n    \"external_directory\": {"
    OPENCODE_JSON="$OPENCODE_JSON\n      \"${DM_WORKSPACE_DIR}/**\": \"allow\""
    OPENCODE_JSON="$OPENCODE_JSON\n    }"
    OPENCODE_JSON="$OPENCODE_JSON\n  }"
  fi

  OPENCODE_JSON="$OPENCODE_JSON\n}"

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would write to $SITE_PATH/opencode.json"
  else
    echo -e "$OPENCODE_JSON" > "$SITE_PATH/opencode.json"
  fi
}

runtime_generate_instructions() {
  # Generate AGENTS.md (skip if already exists — may have been customized)
  if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/AGENTS.md" ]; then
    log "Phase 8: AGENTS.md already exists — skipping (delete to regenerate)"
  else
    log "Phase 8: Generating AGENTS.md..."

    local agents_tmpl="$SCRIPT_DIR/workspace/AGENTS.md"
    if [ ! -f "$agents_tmpl" ]; then
      error "AGENTS.md template not found at $agents_tmpl"
    fi

    local wp_cli_display="wp $WP_ROOT_FLAG --path=$SITE_PATH"
    if [ "$DRY_RUN" = true ]; then
      echo -e "${BLUE}[dry-run]${NC} Would generate AGENTS.md from template"
    else
      sed "s|{{WP_CLI_CMD}}|$wp_cli_display|g" "$agents_tmpl" > "$SITE_PATH/AGENTS.md"
    fi

    # Remove Data Machine sections if DM not installed
    if [ "$INSTALL_DATA_MACHINE" = false ] && [ -f "$SITE_PATH/AGENTS.md" ]; then
      log "Removing Data Machine references from AGENTS.md..."
      awk '/^### (Data Machine|Workspace)/{skip=1; next} /^### /{skip=0} /^## /{skip=0} !skip' \
        "$SITE_PATH/AGENTS.md" > "$SITE_PATH/AGENTS.md.tmp" 2>/dev/null || true
      mv "$SITE_PATH/AGENTS.md.tmp" "$SITE_PATH/AGENTS.md"
    fi

    # Remove multisite section for single-site installs
    if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/AGENTS.md" ]; then
      IS_MULTISITE="${IS_MULTISITE:-no}"
      if [ "$IS_MULTISITE" != "yes" ]; then
        awk '/^### Multisite/{skip=1; next} /^### /{skip=0} /^## /{skip=0} !skip' \
          "$SITE_PATH/AGENTS.md" > "$SITE_PATH/AGENTS.md.tmp" 2>/dev/null || true
        mv "$SITE_PATH/AGENTS.md.tmp" "$SITE_PATH/AGENTS.md"
      fi
    fi
  fi

  # Copy BOOTSTRAP.md if not already present
  if [ -f "$SCRIPT_DIR/workspace/BOOTSTRAP.md" ] && [ ! -f "$SITE_PATH/BOOTSTRAP.md" ]; then
    run_cmd cp "$SCRIPT_DIR/workspace/BOOTSTRAP.md" "$SITE_PATH/BOOTSTRAP.md"
  elif [ -f "$SITE_PATH/BOOTSTRAP.md" ]; then
    log "BOOTSTRAP.md already exists — skipping"
  fi
}

runtime_merge_mcp_servers() {
  if [ -z "${MCP_SERVERS:-}" ] || [ ! -f "$SITE_PATH/opencode.json" ]; then
    return
  fi

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would merge MCP_SERVERS into opencode.json"
    return
  fi

  command -v jq &>/dev/null || error "MCP_SERVERS requires jq"
  log "Merging MCP servers into opencode.json..."
  jq --argjson mcp "$MCP_SERVERS" '.mcp = $mcp' "$SITE_PATH/opencode.json" \
    > "$SITE_PATH/opencode.json.tmp" \
    && mv "$SITE_PATH/opencode.json.tmp" "$SITE_PATH/opencode.json"
}

runtime_install_hooks() {
  return
}

runtime_skills_dir() {
  echo "$SITE_PATH/.opencode/skills"
}

runtime_print_summary() {
  echo "OpenCode:"
  echo "  Config:   $SITE_PATH/opencode.json"
  if [ -n "$OPENCODE_MODEL" ]; then
    echo "  Model:    $OPENCODE_MODEL"
  else
    echo "  Model:    (OpenCode default — zen free models)"
  fi
  echo ""
}
