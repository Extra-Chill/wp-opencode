# WP-OpenCode

**Give your AI agent a home.**

Deploy a WordPress site that your AI agent controls — not just edits, but *runs*. A VPS becomes your agent's headquarters with WP-CLI access, self-scheduling capabilities, and 24/7 autonomous operation.

Uses [OpenCode](https://opencode.ai) as the agent runtime with pluggable chat interfaces (e.g., [Kimaki](https://kimaki.xyz) for Discord).

## How It Works

1. **Add the setup skill to your local coding agent** (Claude Code, Cursor, etc.)
2. **Tell your agent:** "Help me set up wp-opencode"
3. **Your agent guides you through VPS selection and runs the setup**
4. **Your agent wakes up on the VPS** — reads its bootstrap file and starts operating

## Quick Start

### Recommended: Let Your Agent Do It

Add the `wp-opencode-setup` skill to your local coding agent:

```
skills/wp-opencode-setup/
```

Then just ask: "Help me set up wp-opencode on a new VPS"

### Manual Alternative

```bash
ssh root@your-server-ip
git clone https://github.com/Extra-Chill/wp-opencode.git
cd wp-opencode
SITE_DOMAIN=yourdomain.com ./setup.sh
systemctl start kimaki
```

## Setup Options

| Flag | Description |
|------|-------------|
| `--existing` | Add OpenCode to existing WordPress (skip WP install) |
| `--no-data-machine` | Skip Data Machine (no persistent memory/scheduling) |
| `--no-chat` | Skip chat bridge installation |
| `--chat <bridge>` | Chat bridge to install (default: kimaki) |
| `--multisite` | Convert to WordPress Multisite (subdirectory by default) |
| `--subdomain` | Use subdomain multisite (use with `--multisite`) |
| `--no-skills` | Skip WordPress agent skills installation |
| `--skip-deps` | Skip apt package installation |
| `--skip-ssl` | Skip SSL/HTTPS configuration |
| `--root` | Run agent as root (default: dedicated service user) |
| `--dry-run` | Print commands without executing |

### Examples

```bash
# Fresh install with full autonomy + Discord
SITE_DOMAIN=example.com ./setup.sh

# Fresh install, no chat bridge
SITE_DOMAIN=example.com ./setup.sh --no-chat

# Existing WordPress
EXISTING_WP=/var/www/mysite ./setup.sh --existing

# WordPress Multisite (subdomain)
SITE_DOMAIN=example.com ./setup.sh --multisite --subdomain

# Test run
SITE_DOMAIN=example.com ./setup.sh --dry-run
```

## What Gets Installed

- **WordPress** — Pre-configured for AI management
- **[OpenCode](https://opencode.ai)** — AI coding agent runtime
- **[Data Machine](https://github.com/Extra-Chill/data-machine)** — Persistent memory + self-scheduling (optional)
- **[Kimaki](https://kimaki.xyz)** — Discord chat bridge (optional)
- **Agent Skills** — WordPress development skills from [WordPress/agent-skills](https://github.com/WordPress/agent-skills)

## With or Without Data Machine

**Include Data Machine (default) when:**
- You want persistent agent memory (SOUL.md, USER.md, MEMORY.md)
- Agent should schedule its own tasks and reminders
- Running automated content pipelines

**Skip Data Machine (`--no-data-machine`) when:**
- Development-focused setup (coding assistance only)
- Agent only needs to respond when prompted
- No recurring workflows needed

## Requirements

- Linux server (Ubuntu/Debian recommended)
- Node.js 18+
- PHP 8.0+
- MySQL/MariaDB
- nginx

## Documentation

- [docs/changelog.md](docs/changelog.md) — Release history

## Related Projects

- **[wp-openclaw](https://github.com/Sarai-Chinwag/wp-openclaw)** — Same concept, uses [OpenClaw](https://github.com/openclaw/openclaw) as the agent runtime instead of OpenCode

## Contributing

Issues + PRs welcome.

## License

MIT — see [LICENSE](LICENSE)

---

*Built by [Extra Chill](https://extrachill.com) — independent music, independent tools.*
