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

SKILL_FILE="$TARGET_ROOT/skills/easy-loop/SKILL.md"
README_FILE="$TARGET_ROOT/README.md"

python3 - "$SKILL_FILE" "$README_FILE" "$TARGET_ROOT" <<'PY'
from pathlib import Path
import re
import sys

skill_path = Path(sys.argv[1])
readme_path = Path(sys.argv[2])
target_root = sys.argv[3]

if not skill_path.is_file():
    raise SystemExit(f"missing skill file: {skill_path}")

if not readme_path.is_file():
    raise SystemExit(f"missing README file: {readme_path}")

skill = skill_path.read_text(encoding="utf-8")
readme = readme_path.read_text(encoding="utf-8")
skill_flat = re.sub(r"\s+", " ", skill).strip()
readme_flat = re.sub(r"\s+", " ", readme).strip()


def require_contains(text: str, needle: str, label: str) -> None:
    if needle not in text:
        raise SystemExit(f"{label} is missing required text: {needle}")


def require_order(text: str, needles: list[str], label: str) -> None:
    cursor = -1
    for needle in needles:
        idx = text.find(needle, cursor + 1)
        if idx == -1:
            raise SystemExit(f"{label} is missing ordered text: {needle}")
        cursor = idx


skill_required = [
    "Treat `$easy-loop status` and `$easy-loop cancel` as explicit commands.",
    "Treat `$easy-loop <task goal>` as a start request.",
    "If a bare `$easy-loop` appears and the current session already has state on disk, inspect status first before suggesting a restart.",
    "If a bare `$easy-loop` appears and the current session has no state, ask the user to reply with one of:",
    "For a bare `$easy-loop` response with no state, prefer a short action picker that begins with `This session does not have an Easy Loop state file yet.`",
    "For a startup-draft response, begin with `Here is the startup draft I would use:`",
    "For a status response, begin with `Current status: <status>`.",
    "For a cancel response, begin with `I ran:` before reporting the cancellation result.",
    "Show the startup draft and let the user confirm or adjust it before calling `setup.sh`.",
    "End the startup-draft response with a direct confirmation request that uses the literal word `confirm`, for example: `Reply with confirm to start Easy Loop with this draft, or send adjustments.`",
    "Explicitly say that the loop has not been started yet.",
    "Do not call `setup.sh` until the user explicitly confirms the draft or sends adjustments that resolve the open questions.",
    "Do not treat the original `$easy-loop <task goal>` request or user silence as confirmation.",
    "After startup, report the session id, state file path, and that `$easy-loop` can be used later to inspect status.",
    "Also report the iterations file path, configured `max-iterations`, and the completion promise text or `none`.",
    "When reporting status, prioritize current status, current iteration, total elapsed time, recent per-iteration timings, and a terminal summary if the loop already finished.",
    "For terminal status responses, include one explicit stop-reason sentence before the timing summary.",
    "Treat `completed`, `cancelled`, `max_iterations_reached`, and `corrupted` as terminal statuses.",
    "Use the current-session cancel command by default:",
    "bash ~/.codex/plugins/easy-loop/scripts/cancel.sh",
    "bash ~/.codex/plugins/easy-loop/scripts/cancel.sh --session-id <id> --force",
]

for needle in skill_required:
    require_contains(skill_flat, needle, "SKILL.md")

require_order(
    skill_flat,
    [
        "Treat `$easy-loop status` and `$easy-loop cancel` as explicit commands.",
        "Treat `$easy-loop <task goal>` as a start request.",
        "If a bare `$easy-loop` appears and the current session already has state on disk, inspect status first before suggesting a restart.",
        "If a bare `$easy-loop` appears and the current session has no state, ask the user to reply with one of:",
    ],
    "SKILL.md interaction flow",
)

require_order(
    skill_flat,
    [
        "Build a compact startup draft with:",
        "Show the startup draft and let the user confirm or adjust it before calling `setup.sh`.",
        "End the startup-draft response with a direct confirmation request that uses the literal word `confirm`, for example: `Reply with confirm to start Easy Loop with this draft, or send adjustments.`",
        "Explicitly say that the loop has not been started yet.",
        "Do not call `setup.sh` until the user explicitly confirms the draft or sends adjustments that resolve the open questions.",
        "Run the setup script from the current working directory and active Codex session:",
    ],
    "SKILL.md start flow",
)

readme_required = [
    "### Complete Skill Example",
    "- `$easy-loop <task goal>` starts a loop",
    "- `$easy-loop status` reports the current session's loop status",
    "- `$easy-loop cancel` cancels the current session's active loop",
    "Reply with confirm to start Easy Loop with this draft, or send adjustments.",
    "I have not started the loop yet, and I will not call setup.sh until you confirm.",
    "Confirm. Start the loop with that draft.",
    "Easy Loop activated.",
    "State file:",
    "Iterations file:",
    "Max iterations:",
    "Completion promise:",
    "Current status: active",
    "Recent per-iteration timings:",
    "Cancelled the active Easy Loop for session",
    "A bare `$easy-loop` is not enough to start a new loop by itself.",
    "If the current session already has Easy Loop state on disk, the skill should inspect that state before suggesting a restart.",
    "To inspect status later, use `$easy-loop status` in that session.",
]

for needle in readme_required:
    require_contains(readme_flat, needle, "README.md")

require_order(
    readme_flat,
    [
        "User: $easy-loop Update README.md with a complete skill-trigger example, then run bash tests/smoke.sh until it passes.",
        "Here is the startup draft I would use:",
        "Reply with confirm to start Easy Loop with this draft, or send adjustments.",
        "I have not started the loop yet, and I will not call setup.sh until you confirm.",
        "User: Confirm. Start the loop with that draft.",
        "I am starting the loop in this repo with:",
        "Easy Loop activated.",
        "User: $easy-loop status",
        "Current status: active",
        "User: $easy-loop cancel",
        "Cancelled the active Easy Loop for session",
    ],
    "README.md example flow",
)

print(f"interaction contract passed for {target_root}")
PY
