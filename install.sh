#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${INTROSPECT_REPO_URL:-https://github.com/companion-inc/introspect.git}"
RUNTIME_DIR="${INTROSPECT_RUNTIME_DIR:-$HOME/.introspect/runtime}"
PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"

mkdir -p "$BIN_DIR" "$(dirname "$RUNTIME_DIR")"

if [[ -d "$RUNTIME_DIR/.git" ]]; then
  git -C "$RUNTIME_DIR" fetch --depth=1 origin main
  git -C "$RUNTIME_DIR" reset --hard origin/main
elif [[ -d "$RUNTIME_DIR" ]]; then
  echo "install: $RUNTIME_DIR exists but is not a git checkout" >&2
  exit 1
else
  git clone --depth=1 "$REPO_URL" "$RUNTIME_DIR"
fi

chmod +x "$RUNTIME_DIR/bin/introspect" "$RUNTIME_DIR/scripts/install-hooks.sh" "$RUNTIME_DIR/scripts/introspect-status.sh"
ln -sfn "$RUNTIME_DIR/bin/introspect" "$BIN_DIR/introspect"

cat <<EOF
Installed Introspect CLI:

  $BIN_DIR/introspect

Add this to your shell PATH if needed:

  export PATH="$BIN_DIR:\$PATH"

Start here:

  introspect
  introspect install
  introspect status
EOF
