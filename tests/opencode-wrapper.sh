#!/bin/bash
# tests/opencode-wrapper.sh — regression tests for the Kimaki OpenCode wrapper.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

PASS=0
FAIL=0

log() { :; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

assert_file_contains() {
  local label="$1" file="$2" needle="$3"
  if grep -qF "$needle" "$file"; then
    echo "  ok   $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL $label"
    echo "       expected $file to contain: $needle"
    FAIL=$((FAIL+1))
  fi
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ok   $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL $label"
    echo "       expected: '$expected'"
    echo "       actual:   '$actual'"
    FAIL=$((FAIL+1))
  fi
}

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# shellcheck disable=SC1091
source runtimes/opencode.sh
UPDATED_ITEMS=()

make_real_opencode() {
  local real_dir="$TMPDIR_TEST/real/bin"
  mkdir -p "$real_dir"
  cat > "$real_dir/opencode" <<'EOF'
#!/bin/sh
echo real opencode "$@"
EOF
  chmod +x "$real_dir/opencode"
  printf '%s/opencode' "$real_dir"
}

make_stale_wrapper() {
  local wrapper="$1" real_bin="$2"
  cat > "$wrapper" <<EOF
#!/usr/bin/env bash
set -euo pipefail
AUTH_SRC="\${HOME}/.claude/.credentials.json"
AUTH_DST="\${HOME}/.local/share/opencode/auth.json"
if [[ -f "\$AUTH_SRC" ]]; then
  mkdir -p "\$(dirname "\$AUTH_DST")"
  cp "\$AUTH_SRC" "\$AUTH_DST"
fi
exec "$real_bin" "\$@"
EOF
  chmod +x "$wrapper"
}

echo "==> stale wrapper replacement"
REAL_BIN="$(make_real_opencode)"
BIN_DIR="$TMPDIR_TEST/bin"
mkdir -p "$BIN_DIR"
STALE_WRAPPER="$BIN_DIR/opencode"
make_stale_wrapper "$STALE_WRAPPER" "$REAL_BIN"

CHAT_BRIDGE=kimaki
LOCAL_MODE=false
DRY_RUN=false
PATH="$BIN_DIR:$PATH"

_install_opencode_wrapper

assert_file_contains "writes current wrapper sentinel" "$STALE_WRAPPER" "# wp-coding-agents-opencode-wrapper-v2"
assert_file_contains "preserves real binary target" "$STALE_WRAPPER" "exec \"$REAL_BIN\""
assert_eq "backs up stale wrapper" "1" "$(ls "$BIN_DIR"/opencode.bak.* 2>/dev/null | wc -l | tr -d ' ')"

_install_opencode_wrapper

assert_eq "current wrapper rerun is idempotent" "1" "$(ls "$BIN_DIR"/opencode.bak.* 2>/dev/null | wc -l | tr -d ' ')"

echo "==> skip gates"
NON_KIMAKI_DIR="$TMPDIR_TEST/non-kimaki/bin"
mkdir -p "$NON_KIMAKI_DIR"
NON_KIMAKI_WRAPPER="$NON_KIMAKI_DIR/opencode"
make_stale_wrapper "$NON_KIMAKI_WRAPPER" "$REAL_BIN"
CHAT_BRIDGE=telegram
LOCAL_MODE=false
PATH="$NON_KIMAKI_DIR:$PATH"
_install_opencode_wrapper
assert_eq "non-kimaki bridge leaves wrapper alone" "0" "$(grep -c 'wp-coding-agents-opencode-wrapper-v2' "$NON_KIMAKI_WRAPPER")"

LOCAL_DIR="$TMPDIR_TEST/local/bin"
mkdir -p "$LOCAL_DIR"
LOCAL_WRAPPER="$LOCAL_DIR/opencode"
make_stale_wrapper "$LOCAL_WRAPPER" "$REAL_BIN"
CHAT_BRIDGE=kimaki
LOCAL_MODE=true
PATH="$LOCAL_DIR:$PATH"
_install_opencode_wrapper
assert_eq "local mode leaves wrapper alone" "0" "$(grep -c 'wp-coding-agents-opencode-wrapper-v2' "$LOCAL_WRAPPER")"

echo "==> upgrade phase guard"
assert_file_contains "upgrade sources opencode runtime for kimaki" upgrade.sh 'source "$SCRIPT_DIR/runtimes/opencode.sh"'
assert_file_contains "upgrade invokes wrapper refresh" upgrade.sh "_install_opencode_wrapper"

echo
if [ "$FAIL" -gt 0 ]; then
  echo "FAILED: $FAIL of $((PASS+FAIL)) assertion(s)"
  exit 1
fi
echo "OK: $PASS / $PASS assertions passed"
