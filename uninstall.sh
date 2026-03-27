#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Uninstall the Easy Loop Codex plugin.

Usage:
  bash uninstall.sh [--plugin-root PATH] [--codex-home PATH] [--agents-home PATH] [--purge]
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
AGENTS_HOME_DIR="${AGENTS_HOME:-$HOME/.agents}"
PLUGIN_ROOT="${EASY_LOOP_PLUGIN_ROOT:-}"
PLUGIN_ROOT_EXPLICIT=0
PURGE=0

if [[ -n "$PLUGIN_ROOT" ]]; then
  PLUGIN_ROOT_EXPLICIT=1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --plugin-root)
      PLUGIN_ROOT="${2:-}"
      PLUGIN_ROOT_EXPLICIT=1
      shift 2
      ;;
    --codex-home)
      CODEX_HOME_DIR="${2:-}"
      shift 2
      ;;
    --agents-home)
      AGENTS_HOME_DIR="${2:-}"
      shift 2
      ;;
    --purge)
      PURGE=1
      shift
      ;;
    *)
      echo "Error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$PLUGIN_ROOT_EXPLICIT" -eq 0 ]]; then
  PLUGIN_ROOT="${CODEX_HOME_DIR}/plugins/easy-loop"
fi

RESULT="$(
  python3 "$SCRIPT_DIR/scripts/bootstrap.py" uninstall \
    --plugin-root "$PLUGIN_ROOT" \
    --codex-home "$CODEX_HOME_DIR" \
    --agents-home "$AGENTS_HOME_DIR"
)"

if [[ "$PURGE" -eq 1 && -d "$PLUGIN_ROOT" ]]; then
  rm -rf "$PLUGIN_ROOT"
fi

cat <<EOF
Easy Loop uninstall complete.

${RESULT}
EOF
