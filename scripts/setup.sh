#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

PROMPT_PARTS=()
MAX_ITERATIONS=0
COMPLETION_PROMISE=""

usage() {
  cat <<'EOF'
Easy Loop setup for Codex

Usage:
  setup.sh <PROMPT...> [--max-iterations N] [--completion-promise TEXT]

Examples:
  CODEX_THREAD_ID=<session> setup.sh Fix the flaky auth test --max-iterations 20 --completion-promise "DONE"
  CODEX_THREAD_ID=<session> setup.sh Build a todo API --completion-promise "READY"
EOF
}

require_cmd jq

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --max-iterations)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --max-iterations requires a numeric value." >&2
        exit 1
      fi
      if ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "Error: --max-iterations must be a non-negative integer." >&2
        exit 1
      fi
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    --completion-promise)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --completion-promise requires text." >&2
        exit 1
      fi
      COMPLETION_PROMISE="$2"
      shift 2
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        PROMPT_PARTS+=("$1")
        shift
      done
      ;;
    *)
      PROMPT_PARTS+=("$1")
      shift
      ;;
  esac
done

PROMPT="${PROMPT_PARTS[*]:-}"
if [[ -z "$PROMPT" ]]; then
  echo "Error: a task prompt is required." >&2
  usage >&2
  exit 1
fi

SESSION_ID="${CODEX_THREAD_ID:-}"
if [[ -z "$SESSION_ID" ]]; then
  echo "Error: CODEX_THREAD_ID is required. Start Easy Loop from an active Codex session." >&2
  exit 1
fi

ensure_cleanup_trap
acquire_session_setup_lock "$SESSION_ID"

EXISTING_DIR=""
if EXISTING_DIR="$(find_session_dir "$SESSION_ID")"; then
  acquire_run_lock "$EXISTING_DIR"
  STATE_FILE="$(state_file_for_run_dir "$EXISTING_DIR")"
  EXISTING_STATUS="$(frontmatter_value "$STATE_FILE" "status")"
  EXISTING_ACTIVE="$(frontmatter_value "$STATE_FILE" "active")"
  if [[ "$EXISTING_STATUS" == "active" || "$EXISTING_ACTIVE" == "true" ]]; then
    echo "Error: an active Easy Loop already exists for session ${SESSION_ID}." >&2
    echo "Cancel it first with: bash ~/.codex/plugins/easy-loop/scripts/cancel.sh" >&2
    exit 1
  fi
  rm -rf "$EXISTING_DIR"
fi

TAG="$(generate_unique_tag "$PROMPT")"
SESSION_DIR="$(run_dir_for_tag "$TAG")"
STATE_FILE="$(state_file_for_run_dir "$SESSION_DIR")"
ITERATIONS_FILE="$(iterations_file_for_run_dir "$SESSION_DIR")"

mkdir -p "$SESSION_DIR"
acquire_run_lock "$SESSION_DIR"
: >"$ITERATIONS_FILE"

NOW="$(timestamp_now)"
SESSION_RAW="$(json_quote "$SESSION_ID")"
PROMISE_RAW="$(json_string_or_null "$COMPLETION_PROMISE")"

cat >"$STATE_FILE" <<EOF
---
active: true
status: active
iteration: 1
session_id: ${SESSION_RAW}
max_iterations: ${MAX_ITERATIONS}
completion_promise: ${PROMISE_RAW}
started_at: $(json_quote "$NOW")
ended_at: null
current_iteration_started_at: $(json_quote "$NOW")
last_transition_at: $(json_quote "$NOW")
last_iteration_elapsed_ms: null
total_elapsed_ms: 0
last_event: started
last_hook_fingerprint: null
last_transcript_turn_fingerprint: null
last_assistant_excerpt: null
---
${PROMPT}
EOF

cat <<EOF
Easy Loop activated.

Session directory: ${SESSION_DIR}
State file: ${STATE_FILE}
Iterations file: ${ITERATIONS_FILE}
Iteration: 1
Max iterations: $(if [[ "$MAX_ITERATIONS" -gt 0 ]]; then echo "$MAX_ITERATIONS"; else echo "unlimited"; fi)
Completion promise: $(if [[ -n "$COMPLETION_PROMISE" ]]; then echo "$COMPLETION_PROMISE"; else echo "none"; fi)
Session id: ${SESSION_ID}

Continue the task in this Codex session. The Stop hook will replay the original prompt until the loop finishes or reaches a terminal state.
EOF
