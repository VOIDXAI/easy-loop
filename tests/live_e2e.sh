#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT=""
KEEP_TEMP=0
SKIP_INSTALL=0
MODEL="${CODEX_LIVE_E2E_MODEL:-}"
PLUGIN_ROOT="${EASY_LOOP_PLUGIN_ROOT:-${HOME}/.codex/plugins/easy-loop}"
LIVE_TIMEOUT_SECONDS="${CODEX_LIVE_E2E_TIMEOUT_SECONDS:-180}"
LOG_DIR=""
ORIGINAL_SETUP_BACKUP=""
ORIGINAL_CANCEL_BACKUP=""
SCENARIO_FILTER=()

usage() {
  cat <<'EOF'
Run manual live end-to-end Easy Loop checks against a real Codex CLI session.

This script:
  - reinstalls the current checkout into the active Codex plugin location
  - temporarily wraps the installed setup/cancel scripts to log invocations
  - launches real `codex exec` / `codex exec resume` turns in throwaway repos

Usage:
  bash tests/live_e2e.sh [--model MODEL] [--scenario NAME] [--keep-temp] [--skip-install]

Scenarios:
  bare_no_state
  start_requires_confirmation
  bare_existing_state
  status_terminal
  status_active
  cancel_active
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found: $cmd" >&2
    exit 1
  fi
}

cleanup() {
  local status=$?

  if [[ -n "$ORIGINAL_SETUP_BACKUP" && -f "$ORIGINAL_SETUP_BACKUP" ]]; then
    cp "$ORIGINAL_SETUP_BACKUP" "$PLUGIN_ROOT/scripts/setup.sh"
    chmod +x "$PLUGIN_ROOT/scripts/setup.sh"
  fi

  if [[ -n "$ORIGINAL_CANCEL_BACKUP" && -f "$ORIGINAL_CANCEL_BACKUP" ]]; then
    cp "$ORIGINAL_CANCEL_BACKUP" "$PLUGIN_ROOT/scripts/cancel.sh"
    chmod +x "$PLUGIN_ROOT/scripts/cancel.sh"
  fi

  if [[ -n "$TMPROOT" && -d "$TMPROOT" && "$KEEP_TEMP" -eq 0 ]]; then
    rm -rf "$TMPROOT"
  fi

  exit "$status"
}

trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --keep-temp)
      KEEP_TEMP=1
      shift
      ;;
    --skip-install)
      SKIP_INSTALL=1
      shift
      ;;
    --model)
      MODEL="${2:-}"
      shift 2
      ;;
    --scenario)
      SCENARIO_FILTER+=("${2:-}")
      shift 2
      ;;
    *)
      echo "Error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_cmd codex
require_cmd git
require_cmd jq
require_cmd mktemp
require_cmd python3
require_cmd timeout

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/easy-loop-live-e2e.XXXXXX")"
LOG_DIR="$TMPROOT/logs"
mkdir -p "$LOG_DIR"

if [[ "$SKIP_INSTALL" -eq 0 ]]; then
  bash "$ROOT_DIR/install.sh" >/dev/null
fi

if [[ ! -x "$PLUGIN_ROOT/scripts/setup.sh" || ! -x "$PLUGIN_ROOT/scripts/cancel.sh" ]]; then
  echo "Error: installed plugin scripts were not found under $PLUGIN_ROOT." >&2
  echo "Hint: run bash ./install.sh first, or adjust EASY_LOOP_PLUGIN_ROOT." >&2
  exit 1
fi

ORIGINAL_SETUP_BACKUP="$TMPROOT/setup.sh.original"
ORIGINAL_CANCEL_BACKUP="$TMPROOT/cancel.sh.original"
cp "$PLUGIN_ROOT/scripts/setup.sh" "$ORIGINAL_SETUP_BACKUP"
cp "$PLUGIN_ROOT/scripts/cancel.sh" "$ORIGINAL_CANCEL_BACKUP"

cat >"$PLUGIN_ROOT/scripts/setup.sh" <<EOF
#!/usr/bin/env bash

set -euo pipefail

LOG_DIR="${LOG_DIR}"

PROMPT_PARTS=()
MAX_ITERATIONS=0
COMPLETION_PROMISE=""

while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --max-iterations)
      MAX_ITERATIONS="\${2:-0}"
      shift 2
      ;;
    --completion-promise)
      COMPLETION_PROMISE="\${2:-}"
      shift 2
      ;;
    --)
      shift
      while [[ \$# -gt 0 ]]; do
        PROMPT_PARTS+=("\$1")
        shift
      done
      ;;
    *)
      PROMPT_PARTS+=("\$1")
      shift
      ;;
  esac
done

PROMPT="\${PROMPT_PARTS[*]:-}"
SESSION_ID="\${CODEX_THREAD_ID:-live-e2e-missing-session}"
NOW="\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SESSION_DIR=".codex/easy-loop/\${SESSION_ID}"
STATE_FILE="\${SESSION_DIR}/state.md"
ITERATIONS_FILE="\${SESSION_DIR}/iterations.jsonl"

mkdir -p "\$SESSION_DIR"
: >"\$ITERATIONS_FILE"

SESSION_RAW="\$(jq -Rn --arg s "\$SESSION_ID" '\$s')"
if [[ -n "\$COMPLETION_PROMISE" ]]; then
  PROMISE_RAW="\$(jq -Rn --arg s "\$COMPLETION_PROMISE" '\$s')"
else
  PROMISE_RAW="null"
fi

printf '%s\t%s\t%s\n' "\$NOW" "\$SESSION_ID" "\$*" >>"\$LOG_DIR/setup.log"

cat >"\$STATE_FILE" <<STATE
---
active: false
status: completed
iteration: 1
session_id: \${SESSION_RAW}
max_iterations: \${MAX_ITERATIONS}
completion_promise: \${PROMISE_RAW}
started_at: "\${NOW}"
ended_at: "\${NOW}"
current_iteration_started_at: "\${NOW}"
last_transition_at: "\${NOW}"
last_iteration_elapsed_ms: 0
total_elapsed_ms: 0
last_event: completed
last_hook_fingerprint: null
last_assistant_excerpt: null
---
\${PROMPT}
STATE

cat <<OUT
Easy Loop activated.

Session directory: \${SESSION_DIR}
State file: \${STATE_FILE}
Iterations file: \${ITERATIONS_FILE}
Iteration: 1
Max iterations: \$(if [[ "\$MAX_ITERATIONS" -gt 0 ]]; then echo "\$MAX_ITERATIONS"; else echo "unlimited"; fi)
Completion promise: \$(if [[ -n "\$COMPLETION_PROMISE" ]]; then echo "\$COMPLETION_PROMISE"; else echo "none"; fi)
Session id: \${SESSION_ID}

Continue the task in this Codex session. The Stop hook will replay the original prompt until the loop finishes or reaches a terminal state.
OUT
EOF
chmod +x "$PLUGIN_ROOT/scripts/setup.sh"

cat >"$PLUGIN_ROOT/scripts/cancel.sh" <<EOF
#!/usr/bin/env bash

set -euo pipefail

LOG_DIR="${LOG_DIR}"
NOW="\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\t%s\t%s\n' "\$NOW" "\${CODEX_THREAD_ID:-live-e2e-missing-session}" "\$*" >>"\$LOG_DIR/cancel.log"

exec "${ORIGINAL_CANCEL_BACKUP}" "\$@"
EOF
chmod +x "$PLUGIN_ROOT/scripts/cancel.sh"

assert_contains_regex() {
  local path="$1"
  local pattern="$2"
  local label="$3"
  if ! python3 - "$path" "$pattern" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
pattern = sys.argv[2]
if not re.search(pattern, text, flags=re.IGNORECASE | re.MULTILINE | re.DOTALL):
    raise SystemExit(1)
PY
  then
    echo "Assertion failed: ${label}" >&2
    echo "Pattern: ${pattern}" >&2
    echo "File: ${path}" >&2
    sed -n '1,220p' "$path" >&2 || true
    exit 1
  fi
}

assert_not_contains_regex() {
  local path="$1"
  local pattern="$2"
  local label="$3"
  if python3 - "$path" "$pattern" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
pattern = sys.argv[2]
if re.search(pattern, text, flags=re.IGNORECASE | re.MULTILINE | re.DOTALL):
    raise SystemExit(0)
raise SystemExit(1)
PY
  then
    echo "Assertion failed: ${label}" >&2
    echo "Unexpected pattern: ${pattern}" >&2
    echo "File: ${path}" >&2
    sed -n '1,220p' "$path" >&2 || true
    exit 1
  fi
}

log_count() {
  local path="$1"
  if [[ -f "$path" ]]; then
    wc -l <"$path" | tr -d '[:space:]'
  else
    echo 0
  fi
}

new_repo() {
  local name="$1"
  local repo="$TMPROOT/${name}/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf '# Live E2E\n' >"$repo/README.md"
  echo "$repo"
}

run_codex_exec() {
  local repo="$1"
  local prompt="$2"
  local prefix="$3"
  local events="$TMPROOT/${prefix}.events.jsonl"
  local last="$TMPROOT/${prefix}.last.txt"
  local args=(
    codex exec
    --json
    --output-last-message "$last"
    --dangerously-bypass-approvals-and-sandbox
    -C "$repo"
  )

  if [[ -n "$MODEL" ]]; then
    args+=(-m "$MODEL")
  fi

  if env -u CODEX_THREAD_ID -u CODEX_SESSION_ID EASY_LOOP_LIVE_E2E_LOG_DIR="$LOG_DIR" timeout "${LIVE_TIMEOUT_SECONDS}s" "${args[@]}" "$prompt" >"$events"; then
    :
  else
    local exit_code=$?
    if [[ "$exit_code" -eq 124 ]]; then
      echo "Error: codex exec timed out after ${LIVE_TIMEOUT_SECONDS}s." >&2
    fi
    sed -n '1,160p' "$events" >&2 || true
    exit "$exit_code"
  fi
  printf '%s\n%s\n' "$events" "$last"
}

run_codex_resume() {
  local repo="$1"
  local thread_id="$2"
  local prompt="$3"
  local prefix="$4"
  local events="$TMPROOT/${prefix}.events.jsonl"
  local last="$TMPROOT/${prefix}.last.txt"
  local args=(
    codex exec resume
    --json
    --output-last-message "$last"
    --dangerously-bypass-approvals-and-sandbox
  )

  if [[ -n "$MODEL" ]]; then
    args+=(-m "$MODEL")
  fi

  (
    cd "$repo"
    if env -u CODEX_THREAD_ID -u CODEX_SESSION_ID EASY_LOOP_LIVE_E2E_LOG_DIR="$LOG_DIR" timeout "${LIVE_TIMEOUT_SECONDS}s" "${args[@]}" "$thread_id" "$prompt" >"$events"; then
      :
    else
      exit_code=$?
      if [[ "$exit_code" -eq 124 ]]; then
        echo "Error: codex exec resume timed out after ${LIVE_TIMEOUT_SECONDS}s." >&2
      fi
      sed -n '1,160p' "$events" >&2 || true
      exit "$exit_code"
    fi
  )
  printf '%s\n%s\n' "$events" "$last"
}

thread_id_from_events() {
  local events="$1"
  local thread_id
  thread_id="$(jq -r 'select(.type=="thread.started") | .thread_id' "$events" | head -n 1)"
  if [[ -z "$thread_id" || "$thread_id" == "null" ]]; then
    echo "Error: failed to extract thread id from $events." >&2
    sed -n '1,120p' "$events" >&2 || true
    exit 1
  fi
  printf '%s\n' "$thread_id"
}

prime_session() {
  local repo="$1"
  local prefix="$2"
  local result events last
  result="$(run_codex_exec "$repo" 'Reply with exactly: ready' "$prefix")"
  events="$(printf '%s' "$result" | sed -n '1p')"
  last="$(printf '%s' "$result" | sed -n '2p')"
  assert_contains_regex "$last" '^ready\s*$' 'prime session should respond with ready'
  thread_id_from_events "$events"
}

write_state_file() {
  local repo="$1"
  local thread_id="$2"
  local active="$3"
  local status="$4"
  local iteration="$5"
  local max_iterations="$6"
  local promise="$7"
  local started_at="$8"
  local ended_at="$9"
  local current_iteration_started_at="${10}"
  local last_transition_at="${11}"
  local last_iteration_elapsed_ms="${12}"
  local total_elapsed_ms="${13}"
  local last_event="${14}"
  local prompt="${15}"
  local excerpt="${16}"

  local session_dir="$repo/.codex/easy-loop/$thread_id"
  local state_file="$session_dir/state.md"
  mkdir -p "$session_dir"

  python3 - "$state_file" "$thread_id" "$active" "$status" "$iteration" "$max_iterations" "$promise" "$started_at" "$ended_at" "$current_iteration_started_at" "$last_transition_at" "$last_iteration_elapsed_ms" "$total_elapsed_ms" "$last_event" "$prompt" "$excerpt" <<'PY'
from pathlib import Path
import json
import sys

path = Path(sys.argv[1])
thread_id = sys.argv[2]
active = sys.argv[3]
status = sys.argv[4]
iteration = sys.argv[5]
max_iterations = sys.argv[6]
promise = sys.argv[7]
started_at = sys.argv[8]
ended_at = sys.argv[9]
current_iteration_started_at = sys.argv[10]
last_transition_at = sys.argv[11]
last_iteration_elapsed_ms = sys.argv[12]
total_elapsed_ms = sys.argv[13]
last_event = sys.argv[14]
prompt = sys.argv[15]
excerpt = sys.argv[16]

promise_raw = json.dumps(promise) if promise else "null"
ended_at_raw = json.dumps(ended_at) if ended_at else "null"
excerpt_raw = json.dumps(excerpt) if excerpt else "null"

text = f"""---
active: {active}
status: {status}
iteration: {iteration}
session_id: {json.dumps(thread_id)}
max_iterations: {max_iterations}
completion_promise: {promise_raw}
started_at: {json.dumps(started_at)}
ended_at: {ended_at_raw}
current_iteration_started_at: {json.dumps(current_iteration_started_at)}
last_transition_at: {json.dumps(last_transition_at)}
last_iteration_elapsed_ms: {last_iteration_elapsed_ms}
total_elapsed_ms: {total_elapsed_ms}
last_event: {last_event}
last_hook_fingerprint: null
last_assistant_excerpt: {excerpt_raw}
---
{prompt}
"""

path.write_text(text, encoding="utf-8")
PY
}

write_iterations_file() {
  local repo="$1"
  local thread_id="$2"
  shift 2
  local iterations_file="$repo/.codex/easy-loop/$thread_id/iterations.jsonl"
  : >"$iterations_file"
  while [[ $# -gt 0 ]]; do
    jq -nc \
      --argjson iteration "$1" \
      --arg started_at "$2" \
      --arg ended_at "$3" \
      --argjson elapsed_ms "$4" \
      --arg event "$5" \
      '{iteration: $iteration, started_at: $started_at, ended_at: $ended_at, elapsed_ms: $elapsed_ms, event: $event}' >>"$iterations_file"
    shift 5
  done
}

run_scenario_bare_no_state() {
  local repo result events last
  repo="$(new_repo bare_no_state)"
  result="$(run_codex_exec "$repo" '$easy-loop' bare_no_state)"
  events="$(printf '%s' "$result" | sed -n '1p')"
  last="$(printf '%s' "$result" | sed -n '2p')"

  thread_id_from_events "$events" >/dev/null
  assert_contains_regex "$last" '\$easy-loop status' 'bare no-state should mention $easy-loop status'
  assert_contains_regex "$last" '\$easy-loop cancel' 'bare no-state should mention $easy-loop cancel'
  assert_contains_regex "$last" '\$easy-loop <task goal>' 'bare no-state should mention $easy-loop <task goal>'
  if [[ "$(log_count "$LOG_DIR/setup.log")" -ne 0 ]]; then
    echo "Assertion failed: bare no-state should not call setup.sh" >&2
    exit 1
  fi
  echo "live e2e passed: bare_no_state"
}

run_scenario_start_requires_confirmation() {
  local repo result events last thread_id before_setup after_setup confirm_result confirm_last
  repo="$(new_repo start_requires_confirmation)"
  before_setup="$(log_count "$LOG_DIR/setup.log")"
  result="$(run_codex_exec "$repo" '$easy-loop Create loop-e2e.txt and stop when the file exists. Do not work the task yet; only prepare the startup draft.' start_requires_confirmation_turn1)"
  events="$(printf '%s' "$result" | sed -n '1p')"
  last="$(printf '%s' "$result" | sed -n '2p')"
  thread_id="$(thread_id_from_events "$events")"

  assert_contains_regex "$last" 'confirm' 'start flow should ask for confirmation'
  assert_contains_regex "$last" 'max[- ]iterations' 'start flow should mention max-iterations'
  assert_contains_regex "$last" 'completion promise' 'start flow should mention completion promise'
  after_setup="$(log_count "$LOG_DIR/setup.log")"
  if [[ "$after_setup" -ne "$before_setup" ]]; then
    echo "Assertion failed: setup.sh should not run before confirmation" >&2
    exit 1
  fi

  confirm_result="$(run_codex_resume "$repo" "$thread_id" 'Confirm. Start the loop with that draft and only report the activation details in this turn.' start_requires_confirmation_turn2)"
  confirm_last="$(printf '%s' "$confirm_result" | sed -n '2p')"
  after_setup="$(log_count "$LOG_DIR/setup.log")"
  if [[ "$after_setup" -ne $((before_setup + 1)) ]]; then
    echo "Assertion failed: setup.sh should run exactly once after confirmation" >&2
    exit 1
  fi
  assert_contains_regex "$confirm_last" 'session|state\.md|iterations\.jsonl|easy loop (activated|is active)' 'confirmation response should report activation details'
  echo "live e2e passed: start_requires_confirmation"
}

run_scenario_bare_existing_state() {
  local repo thread_id result last before_setup after_setup
  repo="$(new_repo bare_existing_state)"
  thread_id="$(prime_session "$repo" bare_existing_state_prime)"
  write_state_file "$repo" "$thread_id" false completed 2 5 DONE \
    2026-03-27T00:00:00Z 2026-03-27T00:01:00Z 2026-03-27T00:00:45Z 2026-03-27T00:01:00Z 15000 60000 completed \
    "Finish the work" "Completed with <promise>DONE</promise>"
  write_iterations_file "$repo" "$thread_id" \
    1 2026-03-27T00:00:00Z 2026-03-27T00:00:45Z 45000 continued \
    2 2026-03-27T00:00:45Z 2026-03-27T00:01:00Z 15000 completed

  before_setup="$(log_count "$LOG_DIR/setup.log")"
  result="$(run_codex_resume "$repo" "$thread_id" '$easy-loop' bare_existing_state_resume)"
  last="$(printf '%s' "$result" | sed -n '2p')"
  after_setup="$(log_count "$LOG_DIR/setup.log")"

  if [[ "$after_setup" -ne "$before_setup" ]]; then
    echo "Assertion failed: bare command with existing state should not call setup.sh" >&2
    exit 1
  fi
  assert_contains_regex "$last" 'completed|current status' 'bare command with existing state should report status'
  echo "live e2e passed: bare_existing_state"
}

run_scenario_status_terminal() {
  local repo thread_id result last
  repo="$(new_repo status_terminal)"
  thread_id="$(prime_session "$repo" status_terminal_prime)"
  write_state_file "$repo" "$thread_id" false completed 2 5 DONE \
    2026-03-27T00:00:00Z 2026-03-27T00:01:00Z 2026-03-27T00:00:45Z 2026-03-27T00:01:00Z 15000 60000 completed \
    "Finish the work" "Completed with <promise>DONE</promise>"
  write_iterations_file "$repo" "$thread_id" \
    1 2026-03-27T00:00:00Z 2026-03-27T00:00:45Z 45000 continued \
    2 2026-03-27T00:00:45Z 2026-03-27T00:01:00Z 15000 completed

  result="$(run_codex_resume "$repo" "$thread_id" '$easy-loop status' status_terminal_resume)"
  last="$(printf '%s' "$result" | sed -n '2p')"

  assert_contains_regex "$last" 'completed|current status' 'status terminal should mention completed status'
  assert_contains_regex "$last" 'iteration|elapsed|tim' 'status terminal should summarize iteration or timing details'
  echo "live e2e passed: status_terminal"
}

run_scenario_status_active() {
  local repo thread_id result last before_setup after_setup
  repo="$(new_repo status_active)"
  thread_id="$(prime_session "$repo" status_active_prime)"
  write_state_file "$repo" "$thread_id" true active 2 5 DONE \
    2026-03-27T00:00:00Z "" 2026-03-27T00:00:45Z 2026-03-27T00:00:45Z 15000 45000 continued \
    "Keep working" "Still working"
  write_iterations_file "$repo" "$thread_id" \
    1 2026-03-27T00:00:00Z 2026-03-27T00:00:45Z 45000 continued

  before_setup="$(log_count "$LOG_DIR/setup.log")"
  result="$(run_codex_resume "$repo" "$thread_id" '$easy-loop status' status_active_resume)"
  last="$(printf '%s' "$result" | sed -n '2p')"
  after_setup="$(log_count "$LOG_DIR/setup.log")"

  if [[ "$after_setup" -ne "$before_setup" ]]; then
    echo "Assertion failed: status should not call setup.sh" >&2
    exit 1
  fi
  assert_contains_regex "$last" 'active|current status' 'status active should mention active status'
  assert_contains_regex "$last" 'iteration|state file|tim' 'status active should include iteration or timing details'
  echo "live e2e passed: status_active"
}

run_scenario_cancel_active() {
  local repo thread_id result last before_cancel after_cancel state_file
  repo="$(new_repo cancel_active)"
  thread_id="$(prime_session "$repo" cancel_active_prime)"
  write_state_file "$repo" "$thread_id" true active 2 5 DONE \
    2026-03-27T00:00:00Z "" 2026-03-27T00:00:45Z 2026-03-27T00:00:45Z 15000 45000 continued \
    "Keep working" "Still working"
  write_iterations_file "$repo" "$thread_id" \
    1 2026-03-27T00:00:00Z 2026-03-27T00:00:45Z 45000 continued

  before_cancel="$(log_count "$LOG_DIR/cancel.log")"
  result="$(run_codex_resume "$repo" "$thread_id" '$easy-loop cancel' cancel_active_resume)"
  last="$(printf '%s' "$result" | sed -n '2p')"
  after_cancel="$(log_count "$LOG_DIR/cancel.log")"

  if [[ "$after_cancel" -ne $((before_cancel + 1)) ]]; then
    echo "Assertion failed: cancel should invoke cancel.sh exactly once" >&2
    exit 1
  fi

  state_file="$repo/.codex/easy-loop/$thread_id/state.md"
  assert_contains_regex "$last" 'cancel' 'cancel response should mention cancellation'
  assert_contains_regex "$state_file" '^status:\s*cancelled$' 'cancel should write cancelled status'
  assert_contains_regex "$state_file" '^active:\s*false$' 'cancel should deactivate the loop'
  echo "live e2e passed: cancel_active"
}

should_run() {
  local name="$1"
  local scenario
  if [[ "${#SCENARIO_FILTER[@]}" -eq 0 ]]; then
    return 0
  fi
  for scenario in "${SCENARIO_FILTER[@]}"; do
    if [[ "$scenario" == "$name" ]]; then
      return 0
    fi
  done
  return 1
}

if should_run bare_no_state; then
  run_scenario_bare_no_state
fi

if should_run start_requires_confirmation; then
  run_scenario_start_requires_confirmation
fi

if should_run bare_existing_state; then
  run_scenario_bare_existing_state
fi

if should_run status_terminal; then
  run_scenario_status_terminal
fi

if should_run status_active; then
  run_scenario_status_active
fi

if should_run cancel_active; then
  run_scenario_cancel_active
fi

echo "live e2e passed"
if [[ "$KEEP_TEMP" -eq 1 ]]; then
  echo "kept temp dir: $TMPROOT"
fi
