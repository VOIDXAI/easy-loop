#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/easy-loop-smoke.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

CODEX_HOME_DIR="$TMPROOT/home/.codex"
AGENTS_HOME_DIR="$TMPROOT/home/.agents"
PLUGIN_ROOT="$CODEX_HOME_DIR/plugins/easy-loop"
CACHE_ROOT="$CODEX_HOME_DIR/plugins/cache/local/easy-loop/local"
WORK_DIR="$TMPROOT/work/repo"

mkdir -p "$CODEX_HOME_DIR" "$AGENTS_HOME_DIR" "$WORK_DIR"

python3 -m py_compile "$ROOT_DIR/scripts/bootstrap.py"
bash -n "$ROOT_DIR/install.sh"
bash -n "$ROOT_DIR/uninstall.sh"
bash -n "$ROOT_DIR/scripts/common.sh"
bash -n "$ROOT_DIR/scripts/setup.sh"
bash -n "$ROOT_DIR/scripts/stop-hook.sh"
bash -n "$ROOT_DIR/scripts/cancel.sh"
bash -n "$ROOT_DIR/tests/interaction_contract.sh"
bash -n "$ROOT_DIR/tests/golden_transcripts.sh"
bash -n "$ROOT_DIR/tests/live_e2e.sh"
bash "$ROOT_DIR/tests/interaction_contract.sh" >/dev/null
bash "$ROOT_DIR/tests/golden_transcripts.sh" >/dev/null

bash "$ROOT_DIR/install.sh" \
  --codex-home "$CODEX_HOME_DIR" \
  --agents-home "$AGENTS_HOME_DIR" >/dev/null

bash "$ROOT_DIR/tests/interaction_contract.sh" --root "$PLUGIN_ROOT" >/dev/null
bash "$ROOT_DIR/tests/interaction_contract.sh" --root "$CACHE_ROOT" >/dev/null
bash "$ROOT_DIR/tests/golden_transcripts.sh" --root "$PLUGIN_ROOT" >/dev/null
bash "$ROOT_DIR/tests/golden_transcripts.sh" --root "$CACHE_ROOT" >/dev/null

test "$(jq -r '.plugins[0].name' "$AGENTS_HOME_DIR/plugins/marketplace.json")" = "easy-loop"
test "$(jq -r '.plugins[0].source.path' "$AGENTS_HOME_DIR/plugins/marketplace.json")" = "./.codex/plugins/easy-loop"
test "$(jq -r '.hooks.Stop[0].hooks[0].statusMessage' "$CODEX_HOME_DIR/hooks.json")" = "Easy Loop stop hook"
test "$(jq -r '.hooks.Stop[0].hooks[0].command' "$CODEX_HOME_DIR/hooks.json")" = "$PLUGIN_ROOT/scripts/stop-hook.sh"
test -f "$CODEX_HOME_DIR/plugins/cache/local/easy-loop/local/.codex-plugin/plugin.json"

grep -q 'plugins = true' "$CODEX_HOME_DIR/config.toml"
grep -q 'codex_hooks = true' "$CODEX_HOME_DIR/config.toml"
grep -q '\[plugins."easy-loop@local"\]' "$CODEX_HOME_DIR/config.toml"

cd "$WORK_DIR"

SESSION_ONE_DIR=".codex/easy-loop/test-session"
SESSION_TWO_DIR=".codex/easy-loop/other-session"
SESSION_THREE_DIR=".codex/easy-loop/max-session"
CONCURRENT_DIR=".codex/easy-loop/concurrent-session"
STATUS_DIR=".codex/easy-loop/status-session"
STATUS_MARKDOWN_DIR=".codex/easy-loop/status-markdown-session"
CORRUPT_ITER_DIR=".codex/easy-loop/corrupt-iteration"
CORRUPT_MAX_DIR=".codex/easy-loop/corrupt-max"
CORRUPT_TIME_DIR=".codex/easy-loop/corrupt-time"
CORRUPT_PROMPT_DIR=".codex/easy-loop/corrupt-prompt"

CODEX_THREAD_ID=test-session bash "$PLUGIN_ROOT/scripts/setup.sh" \
  "Fix the tests" \
  --max-iterations 3 \
  --completion-promise "DONE" >/dev/null

test -f "$SESSION_ONE_DIR/state.md"
test -f "$SESSION_ONE_DIR/iterations.jsonl"
grep -q '^status: active$' "$SESSION_ONE_DIR/state.md"
grep -q '^iteration: 1$' "$SESSION_ONE_DIR/state.md"
grep -q '^active: true$' "$SESSION_ONE_DIR/state.md"

CODEX_THREAD_ID=other-session bash "$PLUGIN_ROOT/scripts/setup.sh" \
  "Keep another loop running" \
  --max-iterations 2 \
  --completion-promise "OTHER_DONE" >/dev/null

test -f "$SESSION_TWO_DIR/state.md"
grep -q '^iteration: 1$' "$SESSION_TWO_DIR/state.md"

if CODEX_THREAD_ID=test-session bash "$PLUGIN_ROOT/scripts/setup.sh" "should fail" >/dev/null 2>&1; then
  echo "Smoke test failed: same session setup should not overwrite an active loop." >&2
  exit 1
fi

HOOK_BLOCK_OUTPUT="$(
  printf '%s' '{"session_id":"test-session","last_assistant_message":"Still working","transcript_path":""}' |
    bash "$PLUGIN_ROOT/scripts/stop-hook.sh"
)"
test "$(printf '%s' "$HOOK_BLOCK_OUTPUT" | jq -r '.decision')" = "block"
test "$(printf '%s' "$HOOK_BLOCK_OUTPUT" | jq -r '.reason')" = "Fix the tests"
grep -q '^iteration: 2$' "$SESSION_ONE_DIR/state.md"
grep -q '^iteration: 1$' "$SESSION_TWO_DIR/state.md"
test "$(jq -r '.event' "$SESSION_ONE_DIR/iterations.jsonl")" = "continued"

printf '%s' '{"session_id":"test-session","last_assistant_message":"Finished the fix. <promise>DONE</promise>","transcript_path":""}' |
  bash "$PLUGIN_ROOT/scripts/stop-hook.sh" >/dev/null

grep -q '^status: completed$' "$SESSION_ONE_DIR/state.md"
grep -q '^active: false$' "$SESSION_ONE_DIR/state.md"
test "$(jq -s 'length' "$SESSION_ONE_DIR/iterations.jsonl")" = "2"
test "$(tail -n 1 "$SESSION_ONE_DIR/iterations.jsonl" | jq -r '.event')" = "completed"

CODEX_THREAD_ID=other-session bash "$PLUGIN_ROOT/scripts/cancel.sh" >/dev/null
grep -q '^status: cancelled$' "$SESSION_TWO_DIR/state.md"
grep -q '^active: false$' "$SESSION_TWO_DIR/state.md"
test "$(jq -s 'length' "$SESSION_TWO_DIR/iterations.jsonl")" = "1"
test "$(tail -n 1 "$SESSION_TWO_DIR/iterations.jsonl" | jq -r '.event')" = "cancelled"

CODEX_THREAD_ID=max-session bash "$PLUGIN_ROOT/scripts/setup.sh" "Hit the ceiling" --max-iterations 1 >/dev/null
printf '%s' '{"session_id":"max-session","last_assistant_message":"Not done yet","transcript_path":""}' |
  bash "$PLUGIN_ROOT/scripts/stop-hook.sh" >/dev/null
grep -q '^status: max_iterations_reached$' "$SESSION_THREE_DIR/state.md"
grep -q '^active: false$' "$SESSION_THREE_DIR/state.md"
test "$(tail -n 1 "$SESSION_THREE_DIR/iterations.jsonl" | jq -r '.event')" = "max_iterations_reached"

CODEX_THREAD_ID=concurrent-session bash "$PLUGIN_ROOT/scripts/setup.sh" "Handle one stop event once" --max-iterations 4 >/dev/null
CONCURRENT_TRANSCRIPT="$WORK_DIR/concurrent-transcript.jsonl"
cat >"$CONCURRENT_TRANSCRIPT" <<'EOF'
{"role":"assistant","message":{"content":[{"type":"text","text":"Parallel work update"}]}}
EOF
HOOK_PAYLOAD="$(jq -nc --arg session_id "concurrent-session" --arg last_assistant_message "Parallel work update" --arg transcript_path "$CONCURRENT_TRANSCRIPT" '{session_id: $session_id, last_assistant_message: $last_assistant_message, transcript_path: $transcript_path}')"
printf '%s' "$HOOK_PAYLOAD" | bash "$PLUGIN_ROOT/scripts/stop-hook.sh" >"$TMPROOT/concurrent-a.json" &
pid_a=$!
printf '%s' "$HOOK_PAYLOAD" | bash "$PLUGIN_ROOT/scripts/stop-hook.sh" >"$TMPROOT/concurrent-b.json" &
pid_b=$!
wait "$pid_a"
wait "$pid_b"
grep -q '^iteration: 2$' "$CONCURRENT_DIR/state.md"
test "$(jq -s 'length' "$CONCURRENT_DIR/iterations.jsonl")" = "1"
test "$(jq -r '.event' "$CONCURRENT_DIR/iterations.jsonl")" = "continued"

CODEX_THREAD_ID=status-session bash "$PLUGIN_ROOT/scripts/setup.sh" "Keep looping until done" --max-iterations 4 --completion-promise "STATUS_DONE" >/dev/null
STATUS_TRANSCRIPT="$WORK_DIR/status-transcript.jsonl"
cat >"$STATUS_TRANSCRIPT" <<'EOF'
{"role":"user","message":{"content":[{"type":"text","text":"$easy-loop status"}]}}
{"role":"assistant","message":{"content":[{"type":"text","text":"Current status: active"}]}}
EOF
STATUS_PAYLOAD="$(jq -nc --arg session_id "status-session" --arg last_assistant_message "Current status: active" --arg transcript_path "$STATUS_TRANSCRIPT" '{session_id: $session_id, last_assistant_message: $last_assistant_message, transcript_path: $transcript_path}')"
STATUS_HOOK_OUTPUT="$(printf '%s' "$STATUS_PAYLOAD" | bash "$PLUGIN_ROOT/scripts/stop-hook.sh")"
test -z "$STATUS_HOOK_OUTPUT"
grep -q '^status: active$' "$STATUS_DIR/state.md"
grep -q '^iteration: 1$' "$STATUS_DIR/state.md"
test "$(jq -s 'length' "$STATUS_DIR/iterations.jsonl")" = "0"

CODEX_THREAD_ID=status-markdown-session bash "$PLUGIN_ROOT/scripts/setup.sh" "Keep looping until done" --max-iterations 4 --completion-promise "STATUS_DONE" >/dev/null
STATUS_MARKDOWN_PAYLOAD="$(jq -nc --arg session_id "status-markdown-session" --arg last_assistant_message $'**Easy Loop Status**\n\n- `status`: `active`\n- `iteration`: `1` of `4`' '{session_id: $session_id, last_assistant_message: $last_assistant_message, transcript_path: ""}')"
STATUS_MARKDOWN_HOOK_OUTPUT="$(printf '%s' "$STATUS_MARKDOWN_PAYLOAD" | bash "$PLUGIN_ROOT/scripts/stop-hook.sh")"
test -z "$STATUS_MARKDOWN_HOOK_OUTPUT"
grep -q '^status: active$' "$STATUS_MARKDOWN_DIR/state.md"
grep -q '^iteration: 1$' "$STATUS_MARKDOWN_DIR/state.md"
test "$(jq -s 'length' "$STATUS_MARKDOWN_DIR/iterations.jsonl")" = "0"

CODEX_THREAD_ID=test-session bash "$PLUGIN_ROOT/scripts/setup.sh" "Fresh run" --max-iterations 2 >/dev/null
grep -q '^status: active$' "$SESSION_ONE_DIR/state.md"
grep -q '^iteration: 1$' "$SESSION_ONE_DIR/state.md"
test "$(jq -s 'length' "$SESSION_ONE_DIR/iterations.jsonl")" = "0"
grep -q '^status: cancelled$' "$SESSION_TWO_DIR/state.md"

CODEX_THREAD_ID=corrupt-iteration bash "$PLUGIN_ROOT/scripts/setup.sh" "Bad iteration" --max-iterations 2 >/dev/null
python3 - "$CORRUPT_ITER_DIR/state.md" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("iteration: 1", "iteration: nope", 1), encoding="utf-8")
PY
printf '%s' '{"session_id":"corrupt-iteration","last_assistant_message":"still running","transcript_path":""}' |
  bash "$PLUGIN_ROOT/scripts/stop-hook.sh" >/dev/null
grep -q '^status: corrupted$' "$CORRUPT_ITER_DIR/state.md"
grep -q '^active: false$' "$CORRUPT_ITER_DIR/state.md"
test "$(jq -s 'length' "$CORRUPT_ITER_DIR/iterations.jsonl")" = "0"

CODEX_THREAD_ID=corrupt-max bash "$PLUGIN_ROOT/scripts/setup.sh" "Bad max" --max-iterations 2 >/dev/null
python3 - "$CORRUPT_MAX_DIR/state.md" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("max_iterations: 2", "max_iterations: nope", 1), encoding="utf-8")
PY
printf '%s' '{"session_id":"corrupt-max","last_assistant_message":"still running","transcript_path":""}' |
  bash "$PLUGIN_ROOT/scripts/stop-hook.sh" >/dev/null
grep -q '^status: corrupted$' "$CORRUPT_MAX_DIR/state.md"
grep -q '^active: false$' "$CORRUPT_MAX_DIR/state.md"
test "$(jq -s 'length' "$CORRUPT_MAX_DIR/iterations.jsonl")" = "0"

CODEX_THREAD_ID=corrupt-time bash "$PLUGIN_ROOT/scripts/setup.sh" "Missing timestamps" --max-iterations 2 >/dev/null
python3 - "$CORRUPT_TIME_DIR/state.md" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = re.sub(r'^started_at: ".*"$', 'started_at: null', text, count=1, flags=re.MULTILINE)
text = re.sub(r'^current_iteration_started_at: ".*"$', 'current_iteration_started_at: null', text, count=1, flags=re.MULTILINE)
path.write_text(text, encoding="utf-8")
PY
printf '%s' '{"session_id":"corrupt-time","last_assistant_message":"still running","transcript_path":""}' |
  bash "$PLUGIN_ROOT/scripts/stop-hook.sh" >/dev/null
grep -q '^status: corrupted$' "$CORRUPT_TIME_DIR/state.md"
grep -q '^active: false$' "$CORRUPT_TIME_DIR/state.md"
test "$(jq -s 'length' "$CORRUPT_TIME_DIR/iterations.jsonl")" = "0"

CODEX_THREAD_ID=corrupt-prompt bash "$PLUGIN_ROOT/scripts/setup.sh" "Prompt will disappear" --max-iterations 2 >/dev/null
python3 - "$CORRUPT_PROMPT_DIR/state.md" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
parts = text.split("---\n", 2)
path.write_text("---\n" + parts[1] + "---\n", encoding="utf-8")
PY
printf '%s' '{"session_id":"corrupt-prompt","last_assistant_message":"still running","transcript_path":""}' |
  bash "$PLUGIN_ROOT/scripts/stop-hook.sh" >/dev/null
grep -q '^status: corrupted$' "$CORRUPT_PROMPT_DIR/state.md"
grep -q '^active: false$' "$CORRUPT_PROMPT_DIR/state.md"
test "$(jq -s 'length' "$CORRUPT_PROMPT_DIR/iterations.jsonl")" = "0"

if [[ ! -f "$SESSION_ONE_DIR/state.md" || ! -f "$SESSION_TWO_DIR/state.md" || ! -f "$SESSION_THREE_DIR/state.md" || ! -f "$CONCURRENT_DIR/state.md" || ! -f "$STATUS_DIR/state.md" || ! -f "$CORRUPT_ITER_DIR/state.md" || ! -f "$CORRUPT_MAX_DIR/state.md" || ! -f "$CORRUPT_TIME_DIR/state.md" || ! -f "$CORRUPT_PROMPT_DIR/state.md" ]]; then
  echo "Smoke test failed: expected per-session state directories were not preserved." >&2
  exit 1
fi

bash "$PLUGIN_ROOT/uninstall.sh" \
  --codex-home "$CODEX_HOME_DIR" \
  --agents-home "$AGENTS_HOME_DIR" >/dev/null

test "$(jq '[.plugins[] | select(.name == "easy-loop")] | length' "$AGENTS_HOME_DIR/plugins/marketplace.json")" = "0"
test "$(jq '(.hooks.Stop // []) | length' "$CODEX_HOME_DIR/hooks.json")" = "0"

echo "smoke test passed"
