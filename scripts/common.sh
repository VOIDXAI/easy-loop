#!/usr/bin/env bash

DEFAULT_STATE_ROOT=".codex/easy-loop"
STATE_ROOT="${EASY_LOOP_STATE_ROOT:-$DEFAULT_STATE_ROOT}"
EASY_LOOP_SESSION_LOCK_TIMEOUT_SECONDS="${EASY_LOOP_SESSION_LOCK_TIMEOUT_SECONDS:-15}"
EASY_LOOP_CLEANUP_TRAP_SET=0
EASY_LOOP_HELD_SESSION_LOCK=""
EASY_LOOP_CLEANUP_PATHS=()

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found: $cmd" >&2
    exit 1
  fi
}

json_quote() {
  jq -Rn --arg s "$1" '$s'
}

json_string_or_null() {
  local value="${1:-}"
  if [[ -n "$value" ]]; then
    json_quote "$value"
  else
    printf 'null'
  fi
}

literal_or_null() {
  local value="${1:-}"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
  else
    printf 'null'
  fi
}

timestamp_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

ensure_cleanup_trap() {
  if [[ "$EASY_LOOP_CLEANUP_TRAP_SET" -eq 1 ]]; then
    return 0
  fi
  trap 'easy_loop_cleanup_paths' EXIT
  EASY_LOOP_CLEANUP_TRAP_SET=1
}

track_cleanup_path() {
  local path="$1"
  EASY_LOOP_CLEANUP_PATHS+=("$path")
}

easy_loop_cleanup_paths() {
  local path
  for path in "${EASY_LOOP_CLEANUP_PATHS[@]:-}"; do
    if [[ -e "$path" || -L "$path" ]]; then
      rm -rf "$path" 2>/dev/null || true
    fi
  done
}

session_dir_for() {
  local session_id="$1"
  printf '%s/%s\n' "${STATE_ROOT%/}" "$session_id"
}

state_file_for() {
  local session_id="$1"
  printf '%s/state.md\n' "$(session_dir_for "$session_id")"
}

iterations_file_for() {
  local session_id="$1"
  printf '%s/iterations.jsonl\n' "$(session_dir_for "$session_id")"
}

session_lock_path_for() {
  local session_id="$1"
  printf '%s/%s.lock\n' "${STATE_ROOT%/}" "$session_id"
}

acquire_session_lock() {
  local session_id="$1"
  local lock_path
  local deadline
  local owner_pid

  lock_path="$(session_lock_path_for "$session_id")"
  mkdir -p "$(dirname "$lock_path")"
  deadline=$((SECONDS + EASY_LOOP_SESSION_LOCK_TIMEOUT_SECONDS))

  while ! ln -s "$$" "$lock_path" 2>/dev/null; do
    owner_pid="$(readlink "$lock_path" 2>/dev/null || true)"
    if [[ -z "$owner_pid" || ! "$owner_pid" =~ ^[0-9]+$ ]]; then
      rm -f "$lock_path" 2>/dev/null || true
      continue
    fi
    if ! kill -0 "$owner_pid" 2>/dev/null; then
      rm -f "$lock_path" 2>/dev/null || true
      continue
    fi
    if (( SECONDS >= deadline )); then
      echo "Error: timed out waiting for Easy Loop session lock for ${session_id}." >&2
      return 1
    fi
    sleep 0.05
  done

  EASY_LOOP_HELD_SESSION_LOCK="$lock_path"
  track_cleanup_path "$lock_path"
}

frontmatter() {
  local path="$1"
  sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$path"
}

frontmatter_value() {
  local path="$1"
  local key="$2"
  frontmatter "$path" | awk -v key="$key" '
    index($0, key ":") == 1 {
      sub(/^[^:]*:[[:space:]]*/, "", $0)
      print
      exit
    }
  '
}

decode_json_string() {
  local raw="${1:-}"
  if [[ -z "$raw" || "$raw" == "null" ]]; then
    printf ''
    return 0
  fi
  printf '%s' "$raw" | jq -Rr 'fromjson'
}

normalize_spaces() {
  perl -0pe 's/^\s+|\s+$//g; s/\s+/ /g'
}

sha256_text() {
  perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)'
}

excerpt_text() {
  python3 -c '
import re
import sys

text = sys.stdin.read()
text = re.sub(r"\s+", " ", text).strip()
limit = 240
if len(text) > limit:
    text = text[: limit - 3].rstrip() + "..."
sys.stdout.write(text)
'
}

format_duration_ms() {
  local raw="${1:-}"
  python3 - "$raw" <<'PY'
import sys

raw = sys.argv[1]
if not raw or raw == "null":
    print("unknown")
    raise SystemExit(0)

ms = int(raw)
if ms < 1000:
    print(f"{ms}ms")
    raise SystemExit(0)

seconds, millis = divmod(ms, 1000)
minutes, seconds = divmod(seconds, 60)
hours, minutes = divmod(minutes, 60)

parts = []
if hours:
    parts.append(f"{hours}h")
if minutes:
    parts.append(f"{minutes}m")
if seconds:
    parts.append(f"{seconds}s")
if millis and not hours:
    parts.append(f"{millis}ms")

print(" ".join(parts) if parts else f"{ms}ms")
PY
}

elapsed_ms_between() {
  local started_at="${1:-}"
  local ended_at="${2:-}"
  if [[ -z "$started_at" || -z "$ended_at" ]]; then
    printf ''
    return 0
  fi

  python3 - "$started_at" "$ended_at" <<'PY'
import sys
from datetime import datetime

def parse(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))

started = parse(sys.argv[1])
ended = parse(sys.argv[2])
delta_ms = int((ended - started).total_seconds() * 1000)
print(max(delta_ms, 0))
PY
}

rewrite_frontmatter_value() {
  local path="$1"
  local key="$2"
  local raw_value="$3"
  rewrite_frontmatter_batch "$path" "${key}=${raw_value}"
}

rewrite_frontmatter_batch() {
  local path="$1"
  shift

  local temp_file
  local updates_file
  local pair
  local key
  local value

  temp_file="$(mktemp "${path}.tmp.XXXXXX")"
  updates_file="$(mktemp "${path}.updates.XXXXXX")"
  track_cleanup_path "$temp_file"
  track_cleanup_path "$updates_file"

  for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    printf '%s\t%s\n' "$key" "$value" >>"$updates_file"
  done

  awk -v updates_file="$updates_file" '
    BEGIN {
      while ((getline line < updates_file) > 0) {
        tab_index = index(line, "\t")
        key = substr(line, 1, tab_index - 1)
        value = substr(line, tab_index + 1)
        updates[key] = value
        pending[key] = 1
        order[++order_count] = key
      }
      close(updates_file)
    }
    /^---$/ {
      if (frontmatter_started == 0) {
        frontmatter_started = 1
        print
        next
      }
      if (frontmatter_ended == 0) {
        for (i = 1; i <= order_count; i += 1) {
          key = order[i]
          if (key in pending) {
            print key ": " updates[key]
            delete pending[key]
          }
        }
        frontmatter_ended = 1
        print
        next
      }
    }
    frontmatter_started == 1 && frontmatter_ended == 0 {
      matched_key = ""
      for (i = 1; i <= order_count; i += 1) {
        candidate = order[i]
        if (index($0, candidate ":") == 1) {
          matched_key = candidate
          break
        }
      }
      if (matched_key != "") {
        print matched_key ": " updates[matched_key]
        delete pending[matched_key]
        next
      }
    }
    { print }
  ' "$path" >"$temp_file"

  mv "$temp_file" "$path"
}

terminalize_state_file() {
  local state_file="$1"
  local now="$2"
  local final_status="$3"
  local final_iteration_elapsed_ms="$4"
  local final_total_elapsed_ms="$5"
  local excerpt_raw="$6"
  local last_hook_fingerprint_raw="${7:-}"
  local last_transcript_turn_fingerprint_raw="${8:-}"

  local updates=(
    "active=false"
    "status=${final_status}"
    "ended_at=$(json_quote "$now")"
    "last_transition_at=$(json_quote "$now")"
    "last_iteration_elapsed_ms=$(literal_or_null "$final_iteration_elapsed_ms")"
    "total_elapsed_ms=$(literal_or_null "$final_total_elapsed_ms")"
    "last_event=${final_status}"
    "last_assistant_excerpt=${excerpt_raw}"
  )

  if [[ -n "$last_hook_fingerprint_raw" ]]; then
    updates+=("last_hook_fingerprint=${last_hook_fingerprint_raw}")
  fi

  if [[ -n "$last_transcript_turn_fingerprint_raw" ]]; then
    updates+=("last_transcript_turn_fingerprint=${last_transcript_turn_fingerprint_raw}")
  fi

  rewrite_frontmatter_batch "$state_file" "${updates[@]}"
}

extract_prompt_text() {
  local path="$1"
  awk '
    /^---$/ { dashes += 1; next }
    dashes >= 2 { print }
  ' "$path" | perl -0pe 's/^\n//'
}

append_iteration_event() {
  local iterations_file="$1"
  local iteration="$2"
  local started_at="$3"
  local ended_at="$4"
  local elapsed_ms="$5"
  local event="$6"

  mkdir -p "$(dirname "$iterations_file")"
  jq -nc \
    --argjson iteration "$iteration" \
    --arg started_at "$started_at" \
    --arg ended_at "$ended_at" \
    --argjson elapsed_ms "$elapsed_ms" \
    --arg event "$event" \
    '{
      iteration: $iteration,
      started_at: $started_at,
      ended_at: $ended_at,
      elapsed_ms: $elapsed_ms,
      event: $event
    }' >>"$iterations_file"
}

print_run_summary() {
  local state_file="$1"
  local iterations_file="$2"

  if [[ ! -f "$state_file" ]]; then
    return 0
  fi

  local status
  local session_id
  local started_at
  local ended_at
  local total_elapsed_ms
  local completion_promise
  local excerpt
  local task
  local iterations_count

  status="$(frontmatter_value "$state_file" "status")"
  session_id="$(decode_json_string "$(frontmatter_value "$state_file" "session_id")")"
  started_at="$(decode_json_string "$(frontmatter_value "$state_file" "started_at")")"
  ended_at="$(decode_json_string "$(frontmatter_value "$state_file" "ended_at")")"
  total_elapsed_ms="$(frontmatter_value "$state_file" "total_elapsed_ms")"
  completion_promise="$(decode_json_string "$(frontmatter_value "$state_file" "completion_promise")")"
  excerpt="$(decode_json_string "$(frontmatter_value "$state_file" "last_assistant_excerpt")")"
  task="$(extract_prompt_text "$state_file")"
  task="$(printf '%s' "$task" | excerpt_text)"

  if [[ -f "$iterations_file" ]]; then
    iterations_count="$(wc -l <"$iterations_file" | tr -d '[:space:]')"
  else
    iterations_count="0"
  fi

  printf 'Easy Loop summary.\n'
  printf 'Session id: %s\n' "${session_id:-unknown}"
  printf 'Status: %s\n' "${status:-unknown}"
  printf 'Task: %s\n' "${task:-"(missing prompt)"}"
  printf 'Started at: %s\n' "${started_at:-unknown}"
  printf 'Ended at: %s\n' "${ended_at:-"(still active)"}"
  printf 'Total elapsed: %s (%s)\n' "$(format_duration_ms "$total_elapsed_ms")" "${total_elapsed_ms:-null}"
  printf 'Iteration records: %s\n' "${iterations_count:-0}"
  printf 'Completion promise: %s\n' "${completion_promise:-none}"
  if [[ -n "$excerpt" ]]; then
    printf 'Last assistant excerpt: %s\n' "$excerpt"
  fi

  if [[ -f "$iterations_file" && -s "$iterations_file" ]]; then
    printf 'Per-iteration:\n'
    jq -r '"  - iteration \(.iteration): \(.event) (\(.elapsed_ms) ms)"' "$iterations_file"
  fi
}
