#!/bin/bash
# Common utilities: colors, logging, command helpers

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[wp-coding-agents]${NC} $1"; }
warn() { echo -e "${YELLOW}[wp-coding-agents]${NC} $1"; }
error() { echo -e "${RED}[wp-coding-agents]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[wp-coding-agents]${NC} $1"; }

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

# Robust git clone for setup-time plugin/skill deps:
#   - Pins HTTP/1.1 to dodge intermittent GitHub HTTP/2 500s seen during
#     fresh setup runs.
#   - Rewrites SSH-style URLs (git@github.com:…) to HTTPS so users with
#     `gh auth status` reporting `Git operations protocol: ssh` but no SSH
#     key registered don't hit cryptic `Permission denied (publickey)`.
#   - Retries with exponential backoff (default 3 attempts: 2s, 4s, 8s)
#     and cleans up partial directories between attempts.
#
# Usage: git_clone_with_retry <url> <dir> [extra git-clone args…]
git_clone_with_retry() {
  local url="$1"
  local dir="$2"
  shift 2 || true
  local max_attempts=3
  local delay=2
  local attempt

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}[dry-run]${NC} git clone $url $dir $* (with HTTPS rewrite + HTTP/1.1 + retry)"
    return 0
  fi

  for attempt in $(seq 1 "$max_attempts"); do
    if git \
        -c http.version=HTTP/1.1 \
        -c "url.https://github.com/.insteadOf=git@github.com:" \
        clone "$@" "$url" "$dir"; then
      return 0
    fi
    if [ "$attempt" -lt "$max_attempts" ]; then
      warn "Clone of $url failed (attempt $attempt/$max_attempts); retrying in ${delay}s..."
      rm -rf "$dir"
      sleep "$delay"
      delay=$((delay * 2))
    fi
  done
  warn "Clone of $url failed after $max_attempts attempts."
  return 1
}
