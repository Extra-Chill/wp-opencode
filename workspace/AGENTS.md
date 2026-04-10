# AGENTS.md

WP-CLI: `{{WP_CLI_CMD}}`

### Data Machine

Data Machine manages your persistent memory. Discover your files: `{{WP_CLI_CMD}} datamachine agent paths`

Update MEMORY.md when you learn something persistent — read it first, append new info.

### WordPress Source

Direct reference material — grep it as needed:
- `wp-content/plugins/` — all plugin source
- `wp-content/themes/` — all theme source
- `wp-includes/` — WordPress core (read-only)

### Workspace

All coding happens in the Data Machine workspace — a managed git sandbox with full read/write access. Discoverable: `{{WP_CLI_CMD}} help datamachine-code workspace`

### Multisite

This is a WordPress multisite. Use `--url` to target specific sites:
```
{{WP_CLI_CMD}} --url=site.example.com <command>
```
Without `--url`, commands default to the main site.

## Rules

- Discover before memorizing — use `--help`
- Don't deploy or version bump without being told
