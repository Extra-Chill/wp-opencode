#!/bin/bash
#
# wp-opencode setup script
# Bootstrap WordPress + Data Machine + OpenCode on a VPS
# with a pluggable chat interface layer.
#
# Usage:
#   Fresh install:    SITE_DOMAIN=example.com ./setup.sh
#   Existing WP:      EXISTING_WP=/var/www/mysite ./setup.sh --existing
#   Without Discord:  ./setup.sh --no-chat
#   Without DM:       ./setup.sh --no-data-machine
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[wp-opencode]${NC} $1"; }
warn() { echo -e "${YELLOW}[wp-opencode]${NC} $1"; }
error() { echo -e "${RED}[wp-opencode]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[wp-opencode]${NC} $1"; }

run_cmd() {
  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} $*"
  else
    "$@"
  fi
}

write_file() {
  local file_path="$1"
  local content="$2"
  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would write to $file_path"
  else
    echo "$content" > "$file_path"
  fi
}

# ============================================================================
# Parse arguments
# ============================================================================

MODE="fresh"
SKIP_DEPS=false
SKIP_SSL=false
INSTALL_DATA_MACHINE=true
INSTALL_CHAT=true
CHAT_BRIDGE="kimaki"
SHOW_HELP=false
DRY_RUN=false
RUN_AS_ROOT=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --existing)
      MODE="existing"
      shift
      ;;
    --skip-deps)
      SKIP_DEPS=true
      shift
      ;;
    --no-data-machine)
      INSTALL_DATA_MACHINE=false
      shift
      ;;
    --no-chat)
      INSTALL_CHAT=false
      shift
      ;;
    --chat)
      CHAT_BRIDGE="$2"
      shift 2
      ;;
    --skip-ssl)
      SKIP_SSL=true
      shift
      ;;
    --root)
      RUN_AS_ROOT=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help|-h)
      SHOW_HELP=true
      shift
      ;;
    *)
      shift
      ;;
  esac
done

if [ "$SHOW_HELP" = true ]; then
  cat << 'HELP'
wp-opencode setup script

Bootstrap WordPress + Data Machine + OpenCode on a fresh VPS,
with a pluggable chat bridge for talking to your agent.

USAGE:
  Fresh install:     SITE_DOMAIN=example.com ./setup.sh
  Existing WordPress: EXISTING_WP=/var/www/mysite ./setup.sh --existing

OPTIONS:
  --existing         Add OpenCode to existing WordPress (skip WP install)
  --no-data-machine  Skip Data Machine plugin (no persistent memory/scheduling)
  --no-chat          Skip chat bridge installation
  --chat <bridge>    Chat bridge to install (default: kimaki)
                     Supported: kimaki (Discord)
  --skip-deps        Skip apt package installation
  --skip-ssl         Skip SSL/HTTPS configuration
  --root             Run agent as root (default: dedicated service user)
  --dry-run          Print commands without executing
  --help, -h         Show this help

ENVIRONMENT VARIABLES:
  SITE_DOMAIN        Domain for fresh install (required)
  SITE_PATH          WordPress path (default: /var/www/$SITE_DOMAIN)
  EXISTING_WP        Path to existing WordPress (required with --existing)
  DB_NAME            Database name (fresh install only)
  DB_USER            Database user (fresh install only)
  DB_PASS            Database password (auto-generated if not set)
  OPENCODE_MODEL     Default model (default: anthropic/claude-sonnet-4-20250514)
  KIMAKI_BOT_TOKEN   Discord bot token (skip interactive setup)

MIGRATION WORKFLOW:
  1. On old server: Export database and wp-content
     mysqldump dbname > backup.sql
     tar -czf wp-content.tar.gz wp-content/

  2. On new VPS: Import and run setup
     mysql dbname < backup.sql
     tar -xzf wp-content.tar.gz -C /var/www/mysite/
     EXISTING_WP=/var/www/mysite ./setup.sh --existing
HELP
  exit 0
fi

# Check root
if [ "$DRY_RUN" = false ] && [ "$EUID" -ne 0 ]; then
  error "Please run as root (sudo ./setup.sh)"
fi

# Detect OS
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS=$ID
else
  if [ "$DRY_RUN" = true ]; then
    OS="ubuntu"
    warn "Cannot detect OS (dry-run mode), assuming Ubuntu"
  else
    error "Cannot detect OS. This script supports Ubuntu/Debian."
  fi
fi

if [[ "$OS" != "ubuntu" && "$OS" != "debian" ]]; then
  if [ "$DRY_RUN" = true ]; then
    warn "Unsupported OS: $OS (continuing in dry-run mode)"
    OS="ubuntu"
  else
    error "This script supports Ubuntu/Debian only. Detected: $OS"
  fi
fi

log "Detected OS: $OS"
log "Mode: $MODE"
log "Chat bridge: $CHAT_BRIDGE"
log "Data Machine: $INSTALL_DATA_MACHINE"
if [ "$DRY_RUN" = true ]; then
  log "Dry-run mode: commands will be printed, not executed"
fi

# ============================================================================
# Detect PHP Version
# ============================================================================

detect_php_version() {
  if command -v php &> /dev/null; then
    PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
    log "Detected existing PHP version: $PHP_VERSION"
    return
  fi

  if [ "$DRY_RUN" = true ]; then
    PHP_VERSION="8.3"
    log "PHP version (dry-run assumed): $PHP_VERSION"
    return
  fi

  apt update -qq 2>/dev/null
  PHP_VERSION=$(apt-cache search '^php[0-9]+\.[0-9]+-fpm$' 2>/dev/null | \
    sed -E 's/^php([0-9]+\.[0-9]+)-fpm.*/\1/' | \
    sort -t. -k1,1nr -k2,2nr | \
    head -1)

  if [ -n "$PHP_VERSION" ]; then
    log "Best available PHP version: $PHP_VERSION"
  else
    PHP_VERSION=""
    warn "Could not detect PHP version, will use system default"
  fi
}

detect_php_version

# ============================================================================
# Configuration
# ============================================================================

if [ "$MODE" = "existing" ]; then
  if [ -z "$EXISTING_WP" ]; then
    error "EXISTING_WP must be set when using --existing mode"
  fi
  if [ "$DRY_RUN" = false ] && [ ! -f "$EXISTING_WP/wp-config.php" ]; then
    error "No wp-config.php found at $EXISTING_WP"
  fi
  SITE_PATH="$EXISTING_WP"
  if [ "$DRY_RUN" = true ]; then
    SITE_DOMAIN="${SITE_DOMAIN:-$(basename "$SITE_PATH")}"
  else
    SITE_DOMAIN=$(cd "$SITE_PATH" && wp option get siteurl --allow-root 2>/dev/null | sed 's|https\?://||' || basename "$SITE_PATH")
  fi
  log "Existing WordPress at: $SITE_PATH ($SITE_DOMAIN)"
else
  SITE_DOMAIN="${SITE_DOMAIN:-example.com}"
  SITE_PATH="${SITE_PATH:-/var/www/$SITE_DOMAIN}"
fi

DB_NAME="${DB_NAME:-wordpress}"
DB_USER="${DB_USER:-wordpress}"
DB_PASS="${DB_PASS:-$(openssl rand -base64 16)}"
WP_ADMIN_USER="${WP_ADMIN_USER:-admin}"
WP_ADMIN_PASS="${WP_ADMIN_PASS:-$(openssl rand -base64 16)}"
WP_ADMIN_EMAIL="${WP_ADMIN_EMAIL:-admin@$SITE_DOMAIN}"
OPENCODE_MODEL="${OPENCODE_MODEL:-anthropic/claude-sonnet-4-20250514}"
OPENCODE_SMALL_MODEL="${OPENCODE_SMALL_MODEL:-anthropic/claude-haiku-4-5}"

# Service user configuration
if [ "$RUN_AS_ROOT" = true ]; then
  SERVICE_USER="root"
  SERVICE_HOME="/root"
  KIMAKI_DATA_DIR="/root/.kimaki"
else
  SERVICE_USER="opencode"
  SERVICE_HOME="/home/opencode"
  KIMAKI_DATA_DIR="/home/opencode/.kimaki"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# Phase 1: System Dependencies
# ============================================================================

if [ "$SKIP_DEPS" = false ]; then
  log "Phase 1: Installing system dependencies..."
  run_cmd apt update
  run_cmd apt upgrade -y

  if [ -n "$PHP_VERSION" ]; then
    PHP_PACKAGES="php${PHP_VERSION}-fpm php${PHP_VERSION}-mysql php${PHP_VERSION}-xml php${PHP_VERSION}-curl php${PHP_VERSION}-mbstring php${PHP_VERSION}-zip php${PHP_VERSION}-gd php${PHP_VERSION}-intl php${PHP_VERSION}-imagick"
  else
    PHP_PACKAGES="php-fpm php-mysql php-xml php-curl php-mbstring php-zip php-gd php-intl php-imagick"
  fi

  run_cmd apt install -y nginx $PHP_PACKAGES mariadb-server git unzip curl wget composer

  if [ -z "$PHP_VERSION" ] && command -v php &> /dev/null; then
    PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
    log "PHP version after install: $PHP_VERSION"
  fi

  # Node.js
  if ! command -v node &> /dev/null || [ "$DRY_RUN" = true ]; then
    log "Installing Node.js..."
    if [ -z "$NODE_VERSION" ]; then
      NODE_VERSION=$(curl -fsSL https://nodejs.org/dist/index.json 2>/dev/null | \
        grep -o '"version":"v[0-9]*' | head -1 | sed 's/"version":"v//')
      NODE_VERSION="${NODE_VERSION:-22}"
    fi
    log "Installing Node.js $NODE_VERSION..."
    if [ "$DRY_RUN" = true ]; then
      echo -e "${BLUE}[dry-run]${NC} curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -"
      echo -e "${BLUE}[dry-run]${NC} apt install -y nodejs"
    else
      curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash -
      apt install -y nodejs
    fi
  else
    log "Node.js already installed: $(node --version)"
  fi

  # WP-CLI
  if ! command -v wp &> /dev/null || [ "$DRY_RUN" = true ]; then
    log "Installing WP-CLI..."
    run_cmd curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    run_cmd chmod +x wp-cli.phar
    run_cmd mv wp-cli.phar /usr/local/bin/wp
  fi
else
  log "Skipping system dependencies (--skip-deps)"
fi

# ============================================================================
# Phase 2: Database (fresh install only)
# ============================================================================

if [ "$MODE" = "fresh" ]; then
  log "Phase 2: Configuring database..."
  run_cmd mysql -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;"
  run_cmd mysql -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
  run_cmd mysql -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"
  run_cmd mysql -e "FLUSH PRIVILEGES;"
else
  log "Phase 2: Using existing database"
fi

# ============================================================================
# Phase 3: WordPress (fresh install only)
# ============================================================================

if [ "$MODE" = "fresh" ]; then
  log "Phase 3: Installing WordPress..."
  run_cmd mkdir -p "$SITE_PATH"
  if [ "$DRY_RUN" = false ]; then
    cd "$SITE_PATH"
  fi

  if [ ! -f wp-config.php ] || [ "$DRY_RUN" = true ]; then
    run_cmd wp core download --allow-root
    run_cmd wp config create --allow-root \
      --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASS" --dbhost="localhost"
    run_cmd wp core install --allow-root \
      --url="https://$SITE_DOMAIN" --title="My Site" \
      --admin_user="$WP_ADMIN_USER" --admin_password="$WP_ADMIN_PASS" \
      --admin_email="$WP_ADMIN_EMAIL"
  fi
  run_cmd chown -R www-data:www-data "$SITE_PATH"
else
  log "Phase 3: Using existing WordPress at $SITE_PATH"
  if [ "$DRY_RUN" = false ]; then
    cd "$SITE_PATH"
  fi
fi

# ============================================================================
# Phase 4: Data Machine Plugin (optional)
# ============================================================================

if [ "$INSTALL_DATA_MACHINE" = true ]; then
  log "Phase 4: Installing Data Machine..."
  DM_PLUGIN_DIR="$SITE_PATH/wp-content/plugins/data-machine"

  if [ ! -d "$DM_PLUGIN_DIR" ] || [ "$DRY_RUN" = true ]; then
    run_cmd git clone https://github.com/Extra-Chill/data-machine.git "$DM_PLUGIN_DIR"
    if [ -f "$DM_PLUGIN_DIR/composer.json" ] || [ "$DRY_RUN" = true ]; then
      run_cmd env COMPOSER_ALLOW_SUPERUSER=1 composer install \
        --no-dev --no-interaction --working-dir="$DM_PLUGIN_DIR" || \
        warn "Composer failed, some Data Machine features may not work"
    fi
  fi

  run_cmd wp plugin activate data-machine --allow-root --path="$SITE_PATH" || \
    warn "Data Machine may already be active"
  run_cmd chown -R www-data:www-data "$DM_PLUGIN_DIR"

  # Create workspace directory for agent file operations
  run_cmd mkdir -p /var/lib/datamachine/workspace
  if [ "$RUN_AS_ROOT" = false ]; then
    run_cmd chown -R "$SERVICE_USER:www-data" /var/lib/datamachine/workspace
  fi
else
  log "Phase 4: Skipping Data Machine (--no-data-machine)"
fi

# ============================================================================
# Phase 5: Nginx (fresh install only)
# ============================================================================

if [ "$MODE" = "fresh" ]; then
  log "Phase 5: Configuring nginx..."

  if [ -n "$PHP_VERSION" ]; then
    PHP_FPM_SOCK="/var/run/php/php${PHP_VERSION}-fpm.sock"
  else
    if [ "$DRY_RUN" = false ]; then
      PHP_FPM_SOCK=$(find /var/run/php -name "php*-fpm.sock" 2>/dev/null | head -1)
    fi
    PHP_FPM_SOCK="${PHP_FPM_SOCK:-/var/run/php/php-fpm.sock}"
  fi

  NGINX_CONFIG="server {
    listen 80;
    server_name $SITE_DOMAIN www.$SITE_DOMAIN;
    root $SITE_PATH;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_FPM_SOCK;
    }

    location ~ /\.ht {
        deny all;
    }
}"

  write_file "/etc/nginx/sites-available/$SITE_DOMAIN" "$NGINX_CONFIG"
  run_cmd ln -sf "/etc/nginx/sites-available/$SITE_DOMAIN" /etc/nginx/sites-enabled/

  if [ "$DRY_RUN" = false ]; then
    nginx -t && systemctl reload nginx
  fi
  run_cmd systemctl enable nginx
  if [ -n "$PHP_VERSION" ]; then
    run_cmd systemctl enable "php${PHP_VERSION}-fpm"
  fi
else
  log "Phase 5: Using existing nginx configuration"
fi

# ============================================================================
# Phase 5.5: SSL (Let's Encrypt)
# ============================================================================

if [ "$SKIP_SSL" = true ]; then
  log "Skipping SSL (--skip-ssl)"
else
  log "Phase 5.5: Configuring SSL..."

  if ! command -v certbot &> /dev/null || [ "$DRY_RUN" = true ]; then
    run_cmd apt install -y certbot python3-certbot-nginx
  fi

  if [ "$DRY_RUN" = false ]; then
    SERVER_IP=$(curl -s -4 ifconfig.me 2>/dev/null || curl -s -4 icanhazip.com 2>/dev/null)
    DOMAIN_IP=$(dig +short "$SITE_DOMAIN" A 2>/dev/null | head -1)

    if [ "$SERVER_IP" = "$DOMAIN_IP" ]; then
      log "DNS verified. Running certbot..."
      if certbot --nginx -d "$SITE_DOMAIN" --non-interactive --agree-tos \
          --email "$WP_ADMIN_EMAIL" --redirect; then
        log "SSL certificate installed!"
      else
        warn "Certbot failed. Run manually: certbot --nginx -d $SITE_DOMAIN"
      fi
    else
      warn "DNS not pointing here yet (expected $SERVER_IP, got $DOMAIN_IP)"
      warn "Run later: certbot --nginx -d $SITE_DOMAIN"
    fi
  fi
fi

# ============================================================================
# Phase 6: Service User
# ============================================================================

if [ "$RUN_AS_ROOT" = false ]; then
  log "Phase 6: Creating service user '$SERVICE_USER'..."

  if ! id -u "$SERVICE_USER" &>/dev/null || [ "$DRY_RUN" = true ]; then
    run_cmd useradd -m -s /bin/bash -G www-data "$SERVICE_USER"
  else
    log "User '$SERVICE_USER' already exists"
    run_cmd usermod -a -G www-data "$SERVICE_USER"
  fi

  # WordPress files need to be group-writable for the agent
  run_cmd chmod -R g+w "$SITE_PATH"
  run_cmd chown -R www-data:www-data "$SITE_PATH"

  # Create kimaki data directory
  run_cmd mkdir -p "$KIMAKI_DATA_DIR"
  run_cmd chown -R "$SERVICE_USER:$SERVICE_USER" "$KIMAKI_DATA_DIR"
else
  log "Phase 6: Running as root (--root)"
  run_cmd mkdir -p "$KIMAKI_DATA_DIR"
fi

# ============================================================================
# Phase 7: OpenCode
# ============================================================================

log "Phase 7: Installing OpenCode..."

if ! command -v opencode &> /dev/null || [ "$DRY_RUN" = true ]; then
  run_cmd npm install -g @anthropic/opencode
else
  log "OpenCode already installed: $(opencode --version 2>/dev/null || echo 'unknown')"
fi

# Generate opencode.json
log "Generating opencode.json..."

if [ "$INSTALL_DATA_MACHINE" = true ]; then
  # Detect multisite uploads path
  # On multisite subsites, uploads live at wp-content/uploads/sites/{id}/
  # On single site or main site, uploads live at wp-content/uploads/
  if [ "$DRY_RUN" = false ] && [ -f "$SITE_PATH/wp-config.php" ]; then
    IS_MULTISITE=$(wp eval 'echo is_multisite() ? "yes" : "no";' --allow-root --path="$SITE_PATH" 2>/dev/null || echo "no")
    if [ "$IS_MULTISITE" = "yes" ]; then
      BLOG_ID=$(wp eval 'echo get_current_blog_id();' --allow-root --path="$SITE_PATH" 2>/dev/null || echo "1")
      if [ "$BLOG_ID" != "1" ]; then
        DM_AGENT_PATH="wp-content/uploads/sites/${BLOG_ID}/datamachine-files/agent"
      else
        DM_AGENT_PATH="wp-content/uploads/datamachine-files/agent"
      fi
      log "Multisite detected (blog_id=$BLOG_ID). Agent files: $DM_AGENT_PATH"
    else
      DM_AGENT_PATH="wp-content/uploads/datamachine-files/agent"
    fi
  else
    DM_AGENT_PATH="wp-content/uploads/datamachine-files/agent"
  fi

  # With Data Machine: inject all 3 agent files into prompt (SOUL → USER → MEMORY)
  OPENCODE_PROMPT="{file:./AGENTS.md}\n{file:./${DM_AGENT_PATH}/SOUL.md}\n{file:./${DM_AGENT_PATH}/USER.md}\n{file:./${DM_AGENT_PATH}/MEMORY.md}"
else
  # Without Data Machine: just AGENTS.md
  OPENCODE_PROMPT='{file:./AGENTS.md}'
fi

OPENCODE_JSON="{
  \"\$schema\": \"https://opencode.ai/config.json\",
  \"model\": \"${OPENCODE_MODEL}\",
  \"small_model\": \"${OPENCODE_SMALL_MODEL}\",
  \"agent\": {
    \"build\": {
      \"mode\": \"primary\",
      \"model\": \"${OPENCODE_MODEL}\",
      \"prompt\": \"${OPENCODE_PROMPT}\"
    },
    \"plan\": {
      \"mode\": \"primary\",
      \"model\": \"${OPENCODE_MODEL}\",
      \"prompt\": \"${OPENCODE_PROMPT}\"
    }
  }
}"

write_file "$SITE_PATH/opencode.json" "$OPENCODE_JSON"

# ============================================================================
# Phase 8: AGENTS.md
# ============================================================================

log "Phase 8: Generating AGENTS.md..."

if [ -f "$SCRIPT_DIR/workspace/AGENTS.md" ]; then
  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} Would generate AGENTS.md from template"
  else
    sed "s|{{SITE_PATH}}|$SITE_PATH|g" "$SCRIPT_DIR/workspace/AGENTS.md" > "$SITE_PATH/AGENTS.md"
  fi
else
  # Inline fallback if template not available
  write_file "$SITE_PATH/AGENTS.md" "# AGENTS.md

## WordPress Environment
Site root: \`$SITE_PATH\`
WP-CLI: \`wp --allow-root --path=$SITE_PATH\`

## Safety
- Don't leak private data
- Don't run destructive commands without asking
- When in doubt, ask
"
fi

# Copy BOOTSTRAP.md if available
if [ -f "$SCRIPT_DIR/workspace/BOOTSTRAP.md" ]; then
  run_cmd cp "$SCRIPT_DIR/workspace/BOOTSTRAP.md" "$SITE_PATH/BOOTSTRAP.md"
fi

# Remove Data Machine sections if DM not installed
if [ "$INSTALL_DATA_MACHINE" = false ]; then
  if [ -f "$SITE_PATH/AGENTS.md" ]; then
    log "Removing Data Machine references from AGENTS.md..."
    awk '/^### Data Machine/{skip=1; next} /^### /{skip=0} /^## /{skip=0} !skip' \
      "$SITE_PATH/AGENTS.md" > "$SITE_PATH/AGENTS.md.tmp" 2>/dev/null || true
    mv "$SITE_PATH/AGENTS.md.tmp" "$SITE_PATH/AGENTS.md"
  fi
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

# ============================================================================
# Phase 9: Chat Bridge
# ============================================================================

if [ "$INSTALL_CHAT" = true ]; then
  log "Phase 9: Installing chat bridge ($CHAT_BRIDGE)..."

  case "$CHAT_BRIDGE" in
    kimaki)
      if ! command -v kimaki &> /dev/null || [ "$DRY_RUN" = true ]; then
        run_cmd npm install -g kimaki
      else
        log "Kimaki already installed: $(kimaki --version 2>/dev/null | head -1)"
      fi

      # Build environment lines for systemd
      ENV_LINES="Environment=HOME=$SERVICE_HOME"
      ENV_LINES="$ENV_LINES\nEnvironment=PATH=/usr/local/bin:/usr/bin:/bin"
      ENV_LINES="$ENV_LINES\nEnvironment=KIMAKI_DATA_DIR=$KIMAKI_DATA_DIR"

      if [ -n "$KIMAKI_BOT_TOKEN" ]; then
        ENV_LINES="$ENV_LINES\nEnvironment=KIMAKI_BOT_TOKEN=$KIMAKI_BOT_TOKEN"
      fi

      # Find kimaki binary
      if [ "$DRY_RUN" = true ]; then
        KIMAKI_BIN="/usr/bin/kimaki"
      else
        KIMAKI_BIN=$(which kimaki 2>/dev/null || echo "/usr/bin/kimaki")
      fi

      SYSTEMD_CONFIG="[Unit]
Description=Kimaki Discord Bot (wp-opencode)
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$SITE_PATH
$(echo -e "$ENV_LINES")
ExecStart=$KIMAKI_BIN --data-dir $KIMAKI_DATA_DIR --auto-restart --no-critique
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target"

      write_file "/etc/systemd/system/kimaki.service" "$SYSTEMD_CONFIG"
      run_cmd systemctl daemon-reload
      run_cmd systemctl enable kimaki
      ;;

    *)
      warn "Unknown chat bridge: $CHAT_BRIDGE"
      warn "Supported bridges: kimaki"
      warn "Skipping chat bridge installation"
      ;;
  esac
else
  log "Phase 9: Skipping chat bridge (--no-chat)"
fi

# ============================================================================
# Done
# ============================================================================

echo ""
echo "=============================================="
if [ "$DRY_RUN" = true ]; then
  echo -e "${YELLOW}wp-opencode dry-run complete!${NC}"
  echo "(No changes were made)"
else
  echo -e "${GREEN}wp-opencode installation complete!${NC}"
fi
echo "=============================================="
echo ""
echo "WordPress:"
echo "  URL:      https://$SITE_DOMAIN"
echo "  Admin:    https://$SITE_DOMAIN/wp-admin"
echo "  Path:     $SITE_PATH"
echo ""
echo "OpenCode:"
echo "  Config:   $SITE_PATH/opencode.json"
echo "  Model:    $OPENCODE_MODEL"
echo ""
if [ "$INSTALL_DATA_MACHINE" = true ]; then
  echo "Data Machine:"
  echo "  Agent files: $SITE_PATH/wp-content/uploads/datamachine-files/agent/"
  echo "  Workspace:   /var/lib/datamachine/workspace/"
  echo ""
fi
echo "Agent:"
if [ "$RUN_AS_ROOT" = true ]; then
  echo "  User:     root"
else
  echo "  User:     $SERVICE_USER (non-root)"
fi
if [ "$INSTALL_CHAT" = true ]; then
  echo "  Bridge:   $CHAT_BRIDGE"
fi
echo ""

# Save credentials
CREDENTIALS_CONTENT="# wp-opencode credentials (keep this secure!)
# Generated: $(date)

SITE_DOMAIN=$SITE_DOMAIN
SITE_PATH=$SITE_PATH
WP_ADMIN_USER=$WP_ADMIN_USER
WP_ADMIN_PASS=$WP_ADMIN_PASS
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASS=$DB_PASS
DATA_MACHINE=$INSTALL_DATA_MACHINE
SERVICE_USER=$SERVICE_USER
CHAT_BRIDGE=$CHAT_BRIDGE"

CREDENTIALS_FILE="$SERVICE_HOME/.wp-opencode-credentials"
write_file "$CREDENTIALS_FILE" "$CREDENTIALS_CONTENT"
run_cmd chmod 600 "$CREDENTIALS_FILE"
log "Credentials saved to $CREDENTIALS_FILE"

echo "=============================================="
echo "Next steps"
echo "=============================================="
echo ""
if [ "$INSTALL_CHAT" = true ] && [ "$CHAT_BRIDGE" = "kimaki" ]; then
  if [ -n "$KIMAKI_BOT_TOKEN" ]; then
    echo "  Bot token configured via KIMAKI_BOT_TOKEN."
    echo "  Start the agent:  systemctl start kimaki"
  else
    echo "  1. Set up Discord bot token:"
    echo "     Option A: Run kimaki interactively first (sets up database)"
    if [ "$RUN_AS_ROOT" = false ]; then
      echo "       su - $SERVICE_USER -c 'cd $SITE_PATH && kimaki'"
    else
      echo "       cd $SITE_PATH && kimaki"
    fi
    echo "     Option B: Set KIMAKI_BOT_TOKEN in the systemd service"
    echo "       systemctl edit kimaki"
    echo "       [Service]"
    echo "       Environment=KIMAKI_BOT_TOKEN=your-token-here"
    echo ""
    echo "  2. Start the agent:  systemctl start kimaki"
  fi
else
  echo "  No chat bridge installed. Run OpenCode manually:"
  echo "    cd $SITE_PATH && opencode"
fi
echo ""
if [ "$INSTALL_DATA_MACHINE" = true ]; then
  echo "  Configure Data Machine:"
  echo "    - Set AI provider API keys in WP Admin → Data Machine → Settings"
  echo "    - Or via WP-CLI: wp datamachine settings --allow-root"
  echo ""
fi
echo "  Your agent will read BOOTSTRAP.md on first run."
echo ""
