#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

FORCE=0
TARGET_SESSION=""

usage() {
  cat <<'EOF'
Cancel the active Easy Loop in the current working directory.

Usage:
  cancel.sh [--session-id ID] [--force]
EOF
}

require_cmd jq
require_cmd perl
require_cmd python3

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --session-id)
      TARGET_SESSION="${2:-}"
      shift 2
      ;;
    *)
      echo "Error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

CURRENT_SESSION="${CODEX_THREAD_ID:-}"
if [[ -z "$TARGET_SESSION" ]]; then
  TARGET_SESSION="$CURRENT_SESSION"
fi

if [[ -z "$TARGET_SESSION" ]]; then
  echo "Error: a target session id is required. Run this inside Codex or pass --session-id." >&2
  exit 1
fi

if [[ "$FORCE" -eq 0 ]]; then
  if [[ -z "$CURRENT_SESSION" ]]; then
    echo "Refusing to cancel without the current Codex session. Use --session-id <id> --force to override." >&2
    exit 1
  fi
  if [[ "$TARGET_SESSION" != "$CURRENT_SESSION" ]]; then
    echo "Refusing to cancel an Easy Loop that belongs to another Codex session. Use --force to override." >&2
    exit 1
  fi
fi

ensure_cleanup_trap
acquire_session_lock "$TARGET_SESSION"

STATE_FILE="$(state_file_for "$TARGET_SESSION")"
ITERATIONS_FILE="$(iterations_file_for "$TARGET_SESSION")"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "No Easy Loop state was found for session ${TARGET_SESSION} in ${STATE_ROOT}."
  exit 0
fi

STATUS="$(frontmatter_value "$STATE_FILE" "status")"
ACTIVE="$(frontmatter_value "$STATE_FILE" "active")"
if [[ "$STATUS" != "active" && "$ACTIVE" != "true" ]]; then
  echo "No active Easy Loop was found for session ${TARGET_SESSION}. Current status: ${STATUS:-unknown}."
  exit 0
fi

NOW="$(timestamp_now)"
ITERATION="$(frontmatter_value "$STATE_FILE" "iteration")"
STARTED_AT="$(decode_json_string "$(frontmatter_value "$STATE_FILE" "started_at")")"
CURRENT_ITERATION_STARTED_AT="$(decode_json_string "$(frontmatter_value "$STATE_FILE" "current_iteration_started_at")")"
LAST_ASSISTANT_EXCERPT_RAW="$(frontmatter_value "$STATE_FILE" "last_assistant_excerpt")"
if [[ -z "$LAST_ASSISTANT_EXCERPT_RAW" ]]; then
  LAST_ASSISTANT_EXCERPT_RAW="null"
fi

if [[ -z "$CURRENT_ITERATION_STARTED_AT" ]]; then
  CURRENT_ITERATION_STARTED_AT="$STARTED_AT"
fi

LAST_ITERATION_ELAPSED_MS="$(elapsed_ms_between "$CURRENT_ITERATION_STARTED_AT" "$NOW")"
TOTAL_ELAPSED_MS="$(elapsed_ms_between "$STARTED_AT" "$NOW")"

if [[ "$ITERATION" =~ ^[0-9]+$ && -n "$CURRENT_ITERATION_STARTED_AT" ]]; then
  append_iteration_event \
    "$ITERATIONS_FILE" \
    "$ITERATION" \
    "$CURRENT_ITERATION_STARTED_AT" \
    "$NOW" \
    "${LAST_ITERATION_ELAPSED_MS:-0}" \
    "cancelled"
fi

terminalize_state_file \
  "$STATE_FILE" \
  "$NOW" \
  "cancelled" \
  "$LAST_ITERATION_ELAPSED_MS" \
  "$TOTAL_ELAPSED_MS" \
  "$LAST_ASSISTANT_EXCERPT_RAW"

echo "Cancelled the active Easy Loop for session ${TARGET_SESSION}."
print_run_summary "$STATE_FILE" "$ITERATIONS_FILE"
