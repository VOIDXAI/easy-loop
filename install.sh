#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Install the Easy Loop Codex plugin into the official personal plugin layout.

Usage:
  bash install.sh [--repo-url URL] [--plugin-root PATH] [--codex-home PATH] [--agents-home PATH]

Notes:
  - Running from a local clone needs no --repo-url.
  - Running a fetched copy of this script needs --repo-url so the plugin repository can be cloned.
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found: $cmd" >&2
    exit 1
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_SOURCE_ROOT=""
if [[ -f "$SCRIPT_DIR/.codex-plugin/plugin.json" ]]; then
  LOCAL_SOURCE_ROOT="$SCRIPT_DIR"
fi

REPO_URL=""
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
AGENTS_HOME_DIR="${AGENTS_HOME:-$HOME/.agents}"
PLUGIN_ROOT="${EASY_LOOP_PLUGIN_ROOT:-}"
PLUGIN_ROOT_EXPLICIT=0

if [[ -n "$PLUGIN_ROOT" ]]; then
  PLUGIN_ROOT_EXPLICIT=1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --repo-url)
      REPO_URL="${2:-}"
      shift 2
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

require_cmd bash
require_cmd jq
require_cmd perl
require_cmd python3

SOURCE_ROOT="$LOCAL_SOURCE_ROOT"
TEMP_SOURCE=""
if [[ -n "$REPO_URL" ]]; then
  require_cmd git
  TEMP_SOURCE="$(mktemp -d)"
  trap '[[ -n "$TEMP_SOURCE" ]] && rm -rf "$TEMP_SOURCE"' EXIT
  git clone --depth 1 "$REPO_URL" "$TEMP_SOURCE/repo" >/dev/null 2>&1
  SOURCE_ROOT="$TEMP_SOURCE/repo"
fi

if [[ -z "$SOURCE_ROOT" ]]; then
  echo "Error: no plugin source tree is available. Run this script from a local clone or pass --repo-url." >&2
  exit 1
fi

RESULT="$(
  python3 "$SOURCE_ROOT/scripts/bootstrap.py" install \
    --source-root "$SOURCE_ROOT" \
    --plugin-root "$PLUGIN_ROOT" \
    --codex-home "$CODEX_HOME_DIR" \
    --agents-home "$AGENTS_HOME_DIR"
)"

cat <<EOF
Easy Loop installation complete.

${RESULT}

Next steps:
  1. Restart Codex if it is already running.
  2. Mention \$easy-loop in a session, or run:
     bash ${PLUGIN_ROOT}/scripts/setup.sh "<task>" --max-iterations 20 --completion-promise "DONE"
EOF
