#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_ROOT="$ROOT_DIR"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      TARGET_ROOT="${2:-}"
      shift 2
      ;;
    *)
      echo "Error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

FIXTURE_DIR="$TARGET_ROOT/tests/fixtures/golden"

python3 - "$FIXTURE_DIR" "$TARGET_ROOT" <<'PY'
from pathlib import Path
import re
import sys

fixture_dir = Path(sys.argv[1])
target_root = sys.argv[2]

if not fixture_dir.is_dir():
    raise SystemExit(f"missing fixture directory: {fixture_dir}")


def read_fixture(name: str) -> tuple[str, str]:
    path = fixture_dir / name
    if not path.is_file():
        raise SystemExit(f"missing fixture file: {path}")
    text = path.read_text(encoding="utf-8")
    flat = re.sub(r"\s+", " ", text).strip()
    return text, flat


def require_contains(text: str, needle: str, label: str) -> None:
    if needle not in text:
        raise SystemExit(f"{label} is missing required text: {needle}")


def require_absent(text: str, needle: str, label: str) -> None:
    if needle in text:
        raise SystemExit(f"{label} unexpectedly contains: {needle}")


def require_order(text: str, needles: list[str], label: str) -> None:
    cursor = -1
    for needle in needles:
        idx = text.find(needle, cursor + 1)
        if idx == -1:
            raise SystemExit(f"{label} is missing ordered text: {needle}")
        cursor = idx


scenarios = {
    "bare_no_state.txt": {
        "ordered": [
            "User: $easy-loop",
            "Codex: This session does not have an Easy Loop state file yet.",
            "Reply with one of:",
            "`$easy-loop status`",
            "`$easy-loop cancel`",
            "`$easy-loop <task goal>`",
        ],
        "absent": [
            "bash ~/.codex/plugins/easy-loop/scripts/setup.sh",
        ],
    },
    "bare_existing_state.txt": {
        "ordered": [
            "User: $easy-loop",
            "Codex: Current status: completed",
            "Current iteration: 2 of 5",
            "State file:",
            "Iterations file:",
            "Recent per-iteration timings:",
            "This session already has Easy Loop state on disk, so I checked status instead of starting a new loop.",
        ],
        "absent": [
            "bash ~/.codex/plugins/easy-loop/scripts/setup.sh",
        ],
    },
    "start_requires_confirmation.txt": {
        "ordered": [
            "User: $easy-loop Update README.md with a complete skill-trigger example, then run bash tests/smoke.sh until it passes.",
            "Codex: Here is the startup draft I would use:",
            "- task:",
            "- acceptance:",
            "- finish condition:",
            "- recommended max-iterations:",
            "- completion promise:",
            "Reply with confirm to start Easy Loop with this draft, or send adjustments.",
            "I have not started the loop yet, and I will not call setup.sh until you confirm.",
            "User: Confirm. Start the loop with that draft.",
            "Codex: I am starting the loop in this repo with:",
            "bash ~/.codex/plugins/easy-loop/scripts/setup.sh",
            "Easy Loop activated.",
            "State file:",
            "Iterations file:",
            "Max iterations:",
            "Completion promise:",
            "Session id:",
        ],
    },
    "status_active.txt": {
        "ordered": [
            "User: $easy-loop status",
            "Codex: Current status: active",
            "Current iteration: 2 of 5",
            "State file:",
            "Iterations file:",
            "Total elapsed:",
            "Recent per-iteration timings:",
        ],
        "absent": [
            "bash ~/.codex/plugins/easy-loop/scripts/setup.sh",
        ],
    },
    "status_terminal.txt": {
        "ordered": [
            "User: $easy-loop status",
            "Codex: Current status: completed",
            "The loop stopped because the completion promise matched.",
            "State file:",
            "Iterations file:",
            "Total elapsed:",
            "Iteration records:",
            "Recent per-iteration timings:",
        ],
        "absent": [
            "bash ~/.codex/plugins/easy-loop/scripts/setup.sh",
        ],
    },
    "cancel_active.txt": {
        "ordered": [
            "User: $easy-loop cancel",
            "Codex: I ran:",
            "bash ~/.codex/plugins/easy-loop/scripts/cancel.sh",
            "Cancelled the active Easy Loop for session",
            "Easy Loop summary.",
            "Status: cancelled",
            "Iteration records:",
            "Per-iteration:",
        ],
    },
}

for fixture_name, rules in scenarios.items():
    original, flat = read_fixture(fixture_name)
    label = fixture_name
    require_order(flat, rules.get("ordered", []), label)
    for needle in rules.get("contains", []):
        require_contains(flat, needle, label)
    for needle in rules.get("absent", []):
        require_absent(flat, needle, label)

start_text, start_flat = read_fixture("start_requires_confirmation.txt")
confirm_marker = "User: Confirm. Start the loop with that draft."
command_marker = "bash ~/.codex/plugins/easy-loop/scripts/setup.sh"
confirm_index = start_flat.find(confirm_marker)
command_index = start_flat.find(command_marker)
if confirm_index == -1 or command_index == -1:
    raise SystemExit("start_requires_confirmation.txt is missing confirmation or setup command")
if command_index < confirm_index:
    raise SystemExit("start_requires_confirmation.txt starts setup.sh before user confirmation")

before_confirm = start_flat[:confirm_index]
if command_marker in before_confirm:
    raise SystemExit("start_requires_confirmation.txt mentions the setup.sh command before user confirmation")

print(f"golden transcripts passed for {target_root}")
PY
