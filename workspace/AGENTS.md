# AGENTS.md

Site root: `{{SITE_PATH}}`
WP-CLI: `wp {{WP_FLAGS}} --path={{SITE_PATH}}`

### Data Machine

Your memory files are discoverable: `wp help datamachine`
Update MEMORY.md when you learn something persistent — read it first, append new info.

### WordPress Source

The full WordPress codebase is on this filesystem — grep it instead of guessing:
- `wp-content/plugins/` — all plugin source
- `wp-content/themes/` — all theme source
- `wp-includes/` — WordPress core

### Workspace

Managed git workspace at `/var/lib/datamachine/workspace/`. Discoverable: `wp help datamachine-code workspace`

### Multisite

This is a WordPress multisite. Use `--url` to target specific sites:
```
wp {{WP_FLAGS}} --url=site.example.com <command>
```
Without `--url`, commands default to the main site.

## Rules

- Discover before memorizing — use `--help`
- Don't deploy or version bump without being told
