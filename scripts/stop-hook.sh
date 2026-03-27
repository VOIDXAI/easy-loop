#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

HOOK_INPUT="$(cat)"

require_cmd jq
require_cmd perl
require_cmd python3

extract_transcript_fallback() {
  local transcript_path="$1"
  if [[ -z "$transcript_path" || "$transcript_path" == "null" || ! -f "$transcript_path" ]]; then
    printf ''
    return 0
  fi

  local last_lines
  last_lines="$(grep '"role":"assistant"' "$transcript_path" | tail -n 100 || true)"
  if [[ -z "$last_lines" ]]; then
    printf ''
    return 0
  fi

  local parsed
  parsed="$(
    printf '%s\n' "$last_lines" | jq -rs '
      map(.message.content[]? | select(.type == "text") | .text) | last // ""
    ' 2>/dev/null || true
  )"
  if [[ -n "$parsed" && "$parsed" != "null" ]]; then
    printf '%s' "$parsed"
  fi
}

extract_last_assistant_transcript_line() {
  local transcript_path="$1"
  if [[ -z "$transcript_path" || "$transcript_path" == "null" || ! -f "$transcript_path" ]]; then
    printf ''
    return 0
  fi

  grep '"role":"assistant"' "$transcript_path" | tail -n 1 || true
}

extract_last_user_text() {
  local transcript_path="$1"
  if [[ -z "$transcript_path" || "$transcript_path" == "null" || ! -f "$transcript_path" ]]; then
    printf ''
    return 0
  fi

  local last_lines
  last_lines="$(grep '"role":"user"' "$transcript_path" | tail -n 100 || true)"
  if [[ -z "$last_lines" ]]; then
    printf ''
    return 0
  fi

  local parsed
  parsed="$(
    printf '%s\n' "$last_lines" | jq -rs '
      map(.message.content[]? | select(.type == "text") | .text) | last // ""
    ' 2>/dev/null || true
  )"
  if [[ -n "$parsed" && "$parsed" != "null" ]]; then
    printf '%s' "$parsed"
  fi
}

extract_promise_text() {
  local text="$1"
  if [[ -z "$text" ]]; then
    printf ''
    return 0
  fi

  printf '%s' "$text" | perl -0777 -ne '
    if (/<promise>(.*?)<\/promise>/s) {
      my $out = $1;
      $out =~ s/^\s+|\s+$//g;
      $out =~ s/\s+/ /g;
      print $out;
    }
  '
}

terminalize_and_exit() {
  local final_status="$1"
  local message="$2"
  local final_iteration_elapsed_ms="$3"
  local final_total_elapsed_ms="$4"
  local excerpt_raw="$5"
  local last_hook_fingerprint_raw="${6:-}"

  terminalize_state_file \
    "$STATE_FILE" \
    "$NOW" \
    "$final_status" \
    "$final_iteration_elapsed_ms" \
    "$final_total_elapsed_ms" \
    "$excerpt_raw" \
    "$last_hook_fingerprint_raw"

  if [[ -n "$message" ]]; then
    printf '%s\n' "$message" >&2
  fi
  print_run_summary "$STATE_FILE" "$ITERATIONS_FILE" >&2
  exit 0
}

{
  IFS= read -r -d '' HOOK_SESSION || true
  IFS= read -r -d '' LAST_OUTPUT || true
  IFS= read -r -d '' TRANSCRIPT_PATH || true
} < <(
  printf '%s' "$HOOK_INPUT" | jq -j '
    (.session_id // ""), "\u0000",
    (.last_assistant_message // ""), "\u0000",
    (.transcript_path // ""), "\u0000"
  '
)

if [[ -z "$HOOK_SESSION" ]]; then
  exit 0
fi

ensure_cleanup_trap

STATE_FILE="$(state_file_for "$HOOK_SESSION")"
ITERATIONS_FILE="$(iterations_file_for "$HOOK_SESSION")"

acquire_session_lock "$HOOK_SESSION"

if [[ ! -f "$STATE_FILE" ]]; then
  exit 0
fi

STATUS="$(frontmatter_value "$STATE_FILE" "status")"
ACTIVE="$(frontmatter_value "$STATE_FILE" "active")"
if [[ "$STATUS" != "active" && "$ACTIVE" != "true" ]]; then
  exit 0
fi

ITERATION_RAW="$(frontmatter_value "$STATE_FILE" "iteration")"
MAX_ITERATIONS_RAW="$(frontmatter_value "$STATE_FILE" "max_iterations")"
STATE_SESSION_RAW="$(frontmatter_value "$STATE_FILE" "session_id")"
COMPLETION_PROMISE_RAW="$(frontmatter_value "$STATE_FILE" "completion_promise")"
STARTED_AT_RAW="$(frontmatter_value "$STATE_FILE" "started_at")"
CURRENT_ITERATION_STARTED_AT_RAW="$(frontmatter_value "$STATE_FILE" "current_iteration_started_at")"
LAST_TRANSITION_AT_RAW="$(frontmatter_value "$STATE_FILE" "last_transition_at")"
LAST_EVENT_RAW="$(frontmatter_value "$STATE_FILE" "last_event")"
LAST_HOOK_FINGERPRINT_RAW="$(frontmatter_value "$STATE_FILE" "last_hook_fingerprint")"

ITERATION="${ITERATION_RAW:-}"
MAX_ITERATIONS="${MAX_ITERATIONS_RAW:-}"
STATE_SESSION="$(decode_json_string "$STATE_SESSION_RAW")"
COMPLETION_PROMISE="$(decode_json_string "$COMPLETION_PROMISE_RAW")"
STARTED_AT="$(decode_json_string "$STARTED_AT_RAW")"
CURRENT_ITERATION_STARTED_AT="$(decode_json_string "$CURRENT_ITERATION_STARTED_AT_RAW")"
LAST_TRANSITION_AT="$(decode_json_string "$LAST_TRANSITION_AT_RAW")"
LAST_EVENT="${LAST_EVENT_RAW:-}"
LAST_HOOK_FINGERPRINT="$(decode_json_string "$LAST_HOOK_FINGERPRINT_RAW")"
NOW="$(timestamp_now)"

if [[ -n "$STATE_SESSION" && "$STATE_SESSION" != "$HOOK_SESSION" ]]; then
  terminalize_and_exit \
    "corrupted" \
    "Easy Loop state was corrupted: session_id does not match the active hook session." \
    "" \
    "$(elapsed_ms_between "$STARTED_AT" "$NOW")" \
    "null"
fi

if [[ -z "$LAST_OUTPUT" ]]; then
  LAST_OUTPUT="$(extract_transcript_fallback "$TRANSCRIPT_PATH")"
fi

LAST_OUTPUT_EXCERPT="$(printf '%s' "$LAST_OUTPUT" | excerpt_text)"
LAST_OUTPUT_EXCERPT_RAW="$(json_string_or_null "$LAST_OUTPUT_EXCERPT")"
HOOK_FINGERPRINT_KIND=""
HOOK_FINGERPRINT_SOURCE="$(extract_last_assistant_transcript_line "$TRANSCRIPT_PATH")"
if [[ -n "$HOOK_FINGERPRINT_SOURCE" ]]; then
  HOOK_FINGERPRINT_KIND="transcript"
elif [[ -n "$LAST_OUTPUT" ]]; then
  HOOK_FINGERPRINT_KIND="message"
  HOOK_FINGERPRINT_SOURCE="$LAST_OUTPUT"
fi

HOOK_FINGERPRINT=""
HOOK_FINGERPRINT_RAW="null"
if [[ -n "$HOOK_FINGERPRINT_SOURCE" ]]; then
  HOOK_FINGERPRINT="$(printf '%s' "$HOOK_FINGERPRINT_SOURCE" | sha256_text)"
  HOOK_FINGERPRINT_RAW="$(json_quote "$HOOK_FINGERPRINT")"
fi

LAST_USER_TEXT="$(extract_last_user_text "$TRANSCRIPT_PATH")"
LAST_USER_TEXT_NORMALIZED="$(printf '%s' "$LAST_USER_TEXT" | normalize_spaces)"
LAST_OUTPUT_NORMALIZED="$(printf '%s' "$LAST_OUTPUT" | normalize_spaces)"

if [[ "$LAST_USER_TEXT_NORMALIZED" == '$easy-loop status' || "$LAST_USER_TEXT_NORMALIZED" == '$easy-loop' ]]; then
  exit 0
fi

case "$LAST_OUTPUT_NORMALIZED" in
  *"Easy Loop Status"* | \
  "Easy Loop status report."* | \
  "Current Easy Loop session "* | \
  "Current status:"* | \
  "Easy Loop is active"* | \
  "Easy Loop is completed"* | \
  "Easy Loop is cancelled"* | \
  "Easy Loop is corrupted"* | \
  "Easy Loop reached max_iterations"* | \
  "Active. Easy Loop for session "* | \
  "Easy Loop for session "*)
    exit 0
    ;;
esac

if [[ ! "$ITERATION" =~ ^[0-9]+$ ]]; then
  terminalize_and_exit \
    "corrupted" \
    "Easy Loop state was corrupted: invalid iteration." \
    "" \
    "$(elapsed_ms_between "$STARTED_AT" "$NOW")" \
    "$LAST_OUTPUT_EXCERPT_RAW" \
    "$HOOK_FINGERPRINT_RAW"
fi

if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
  terminalize_and_exit \
    "corrupted" \
    "Easy Loop state was corrupted: invalid max_iterations." \
    "" \
    "$(elapsed_ms_between "$STARTED_AT" "$NOW")" \
    "$LAST_OUTPUT_EXCERPT_RAW" \
    "$HOOK_FINGERPRINT_RAW"
fi

if [[ -z "$CURRENT_ITERATION_STARTED_AT" ]]; then
  CURRENT_ITERATION_STARTED_AT="$STARTED_AT"
fi

if [[ -z "$CURRENT_ITERATION_STARTED_AT" ]]; then
  terminalize_and_exit \
    "corrupted" \
    "Easy Loop state was corrupted: missing iteration start time." \
    "" \
    "$(elapsed_ms_between "$STARTED_AT" "$NOW")" \
    "$LAST_OUTPUT_EXCERPT_RAW" \
    "$HOOK_FINGERPRINT_RAW"
fi

CURRENT_ITERATION_ELAPSED_MS="$(elapsed_ms_between "$CURRENT_ITERATION_STARTED_AT" "$NOW")"
TOTAL_ELAPSED_MS="$(elapsed_ms_between "$STARTED_AT" "$NOW")"

if [[ -n "$HOOK_FINGERPRINT" && "$HOOK_FINGERPRINT" == "$LAST_HOOK_FINGERPRINT" ]]; then
  if [[ "$HOOK_FINGERPRINT_KIND" == "transcript" ]]; then
    exit 0
  fi

  LAST_TRANSITION_ELAPSED_MS="$(elapsed_ms_between "$LAST_TRANSITION_AT" "$NOW")"
  if [[ "$LAST_EVENT" == "continued" && "$LAST_TRANSITION_ELAPSED_MS" =~ ^[0-9]+$ && "$LAST_TRANSITION_ELAPSED_MS" -le 2000 ]]; then
    exit 0
  fi
fi

if [[ -n "$COMPLETION_PROMISE" ]]; then
  PROMISE_TEXT="$(extract_promise_text "$LAST_OUTPUT")"
  if [[ -n "$PROMISE_TEXT" ]]; then
    NORMALIZED_PROMISE="$(printf '%s' "$PROMISE_TEXT" | normalize_spaces)"
    EXPECTED_PROMISE="$(printf '%s' "$COMPLETION_PROMISE" | normalize_spaces)"
    if [[ "$NORMALIZED_PROMISE" == "$EXPECTED_PROMISE" ]]; then
      append_iteration_event \
        "$ITERATIONS_FILE" \
        "$ITERATION" \
        "$CURRENT_ITERATION_STARTED_AT" \
        "$NOW" \
        "${CURRENT_ITERATION_ELAPSED_MS:-0}" \
        "completed"
      terminalize_and_exit \
        "completed" \
        "Easy Loop completed successfully." \
        "$CURRENT_ITERATION_ELAPSED_MS" \
        "$TOTAL_ELAPSED_MS" \
        "$LAST_OUTPUT_EXCERPT_RAW" \
        "$HOOK_FINGERPRINT_RAW"
    fi
  fi
fi

if [[ "$MAX_ITERATIONS" -gt 0 && "$ITERATION" -ge "$MAX_ITERATIONS" ]]; then
  append_iteration_event \
    "$ITERATIONS_FILE" \
    "$ITERATION" \
    "$CURRENT_ITERATION_STARTED_AT" \
    "$NOW" \
    "${CURRENT_ITERATION_ELAPSED_MS:-0}" \
    "max_iterations_reached"
  terminalize_and_exit \
    "max_iterations_reached" \
    "Easy Loop stopped after reaching max_iterations=${MAX_ITERATIONS}." \
    "$CURRENT_ITERATION_ELAPSED_MS" \
    "$TOTAL_ELAPSED_MS" \
    "$LAST_OUTPUT_EXCERPT_RAW" \
    "$HOOK_FINGERPRINT_RAW"
fi

PROMPT_TEXT="$(extract_prompt_text "$STATE_FILE")"
if [[ -z "$PROMPT_TEXT" ]]; then
  terminalize_and_exit \
    "corrupted" \
    "Easy Loop state was corrupted: missing prompt text." \
    "$CURRENT_ITERATION_ELAPSED_MS" \
    "$TOTAL_ELAPSED_MS" \
    "$LAST_OUTPUT_EXCERPT_RAW" \
    "$HOOK_FINGERPRINT_RAW"
fi

append_iteration_event \
  "$ITERATIONS_FILE" \
  "$ITERATION" \
  "$CURRENT_ITERATION_STARTED_AT" \
  "$NOW" \
  "${CURRENT_ITERATION_ELAPSED_MS:-0}" \
  "continued"

NEXT_ITERATION="$((ITERATION + 1))"
rewrite_frontmatter_batch \
  "$STATE_FILE" \
  "iteration=${NEXT_ITERATION}" \
  "current_iteration_started_at=$(json_quote "$NOW")" \
  "last_transition_at=$(json_quote "$NOW")" \
  "last_iteration_elapsed_ms=$(literal_or_null "$CURRENT_ITERATION_ELAPSED_MS")" \
  "total_elapsed_ms=$(literal_or_null "$TOTAL_ELAPSED_MS")" \
  "last_event=continued" \
  "last_hook_fingerprint=${HOOK_FINGERPRINT_RAW}" \
  "last_assistant_excerpt=${LAST_OUTPUT_EXCERPT_RAW}"

if [[ -n "$COMPLETION_PROMISE" ]]; then
  printf -v SYSTEM_MESSAGE 'Easy Loop iteration %s. Keep working on the same task. When it is fully complete, respond with a concise summary followed by <promise>%s</promise>. Do not emit the promise until it is fully true.' "$NEXT_ITERATION" "$COMPLETION_PROMISE"
else
  printf -v SYSTEM_MESSAGE 'Easy Loop iteration %s. No completion promise is set; the loop ends only on cancellation or max_iterations.' "$NEXT_ITERATION"
fi

jq -n \
  --arg reason "$PROMPT_TEXT" \
  --arg system_message "$SYSTEM_MESSAGE" \
  '{
    decision: "block",
    reason: $reason,
    systemMessage: $system_message
  }'
