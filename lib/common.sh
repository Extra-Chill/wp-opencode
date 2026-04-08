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
