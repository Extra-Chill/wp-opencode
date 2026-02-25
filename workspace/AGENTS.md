# AGENTS.md — WordPress + Data Machine + OpenCode

## Every Session

Before doing anything:
1. Your SOUL.md and MEMORY.md are auto-injected from Data Machine agent files
2. Check the task you received — execute it, report back

## WordPress Environment

Site root: `{{SITE_PATH}}`
WP-CLI: `wp --allow-root --path={{SITE_PATH}}`

### Data Machine (your brain)

Memory files: `wp-content/uploads/datamachine-files/agent/`
- SOUL.md — who you are (auto-injected)
- MEMORY.md — what you know (auto-injected)

CLI access:
```bash
wp datamachine flows list --allow-root
wp datamachine flows queue list <flow_id> --allow-root
wp datamachine flows queue add <flow_id> "task" --allow-root
wp datamachine jobs list --allow-root
wp datamachine logs read pipeline --allow-root
```

### Update MEMORY.md when you learn something new:
```bash
cat wp-content/uploads/datamachine-files/agent/MEMORY.md
# Update it carefully — preserve existing content, append new info
```

## Tools Available

- `wp` — WordPress CLI (always use --allow-root)
- `gh` — GitHub CLI (if authenticated)
- `git` — Version control
- Standard Unix tools (curl, grep, sed, etc.)

## Git Discipline

1. Identify the repo
2. Clone/pull
3. Make changes
4. Commit with meaningful message
5. Push

## Coding Standards

1. PLAN FIRST — state what stays, adds, removes
2. No dead variables
3. No defensive fallbacks hiding init failures
4. Follow existing codebase patterns
5. Test before committing
6. Comprehensive changes — don't leave old code behind

## Safety

- Don't leak private data
- Don't run destructive commands without asking
- NEVER deploy without being told to
- When in doubt, ask
