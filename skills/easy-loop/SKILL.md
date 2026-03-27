---
name: easy-loop
description: >
  Operate the Easy Loop plugin in the current repo to start, inspect, or
  cancel Stop-hook powered retry loops for Codex tasks. Use when the user
  mentions `$easy-loop`, asks Codex to keep iterating on the same task across
  stop boundaries, or needs status or cancellation for an existing Easy Loop
  session.
---

# Easy Loop

Operate the Easy Loop plugin from the current repo.

## Ground Truth

- Treat `scripts/setup.sh`, `scripts/cancel.sh`, `scripts/stop-hook.sh`, and
  `scripts/common.sh` as the authoritative runtime behavior when the skill text
  and implementation diverge.
- Read `README.md` only when the user asks about installation, publishing, or
  repository-level documentation.
- Use the current working directory when reading or writing
  `.codex/easy-loop/<session_id>/`.

## Interaction

- Treat `$easy-loop status` and `$easy-loop cancel` as explicit commands.
- Treat `$easy-loop <task goal>` as a start request.
- If a bare `$easy-loop` appears and the current session already has state on
  disk, inspect status first before suggesting a restart.
- If a bare `$easy-loop` appears and the current session has no state, ask the
  user to reply with one of:
  - `$easy-loop status`
  - `$easy-loop cancel`
  - `$easy-loop <task goal>`
- Prefer `request_user_input` when it is available and the choice is bounded.
  Otherwise ask short plain-text questions.
- Ask only for missing information. Do not re-ask for a clear goal or finish
  condition the user already gave.
- For missing task wording or a truly custom finish condition, ask directly in
  plain text instead of forcing multiple-choice prompts.
- If you ask for a missing task goal in plain text, tell the user to reply with
  `$easy-loop <task goal>`.

## Start A Loop

- Before starting, read `.codex/easy-loop/$CODEX_THREAD_ID/state.md` when it
  exists.
- If the current session is already active, report status instead of starting a
  second loop.
- If the task is missing or too vague, ask for the task goal first.
- Build a compact startup draft with:
  - task wording
  - inferred scope only when it matters
  - expected output or acceptance target
  - finish condition
  - recommended `max-iterations`
  - a unique completion promise
- Preserve a user-supplied finish condition unless it is unsafe or
  contradictory.
- Prefer finish conditions tied to concrete artifacts or verification instead of
  promise text alone.
- Recommend `max-iterations` from the workload when possible. If you cannot
  estimate responsibly, use `20` only as a fallback and say it is a fallback.
- Generate a completion promise that is specific, short, and unlikely to appear
  accidentally in normal prose.
- Show the startup draft and let the user confirm or adjust it before calling
  `setup.sh`.
- End the startup-draft response with a direct confirmation request that uses
  the literal word `confirm`, for example: `Reply with confirm to start Easy
  Loop with this draft, or send adjustments.`
- Explicitly say that the loop has not been started yet.
- Do not call `setup.sh` until the user explicitly confirms the draft or sends
  adjustments that resolve the open questions.
- Do not treat the original `$easy-loop <task goal>` request or user silence as
  confirmation.
- Run the setup script from the current working directory and active Codex
  session:

```bash
bash ~/.codex/plugins/easy-loop/scripts/setup.sh \
  <TASK...> \
  --max-iterations <N> \
  --completion-promise "<TEXT>"
```

- `setup.sh` requires `CODEX_THREAD_ID`.
- If `CODEX_THREAD_ID` is missing, explain that startup must happen from the
  active Codex session that will own the loop.
- After startup, report the session id, state file path, and that `$easy-loop`
  can be used later to inspect status.
- Also report the iterations file path, configured `max-iterations`, and the
  completion promise text or `none`.
- If the current session already has terminal state on disk and the user wants
  to start over, explain that the next `setup.sh` will replace that old state.

## Monitor A Loop

- For the current session, read:
  - `.codex/easy-loop/$CODEX_THREAD_ID/state.md`
  - `.codex/easy-loop/$CODEX_THREAD_ID/iterations.jsonl`
- If the current session has no state file, scan `.codex/easy-loop/*/state.md`
  to see whether other Codex sessions in the same repo still have loops.
- When reporting status, prioritize current status, current iteration, total
  elapsed time, recent per-iteration timings, and a terminal summary if the loop
  already finished.
- For terminal sessions, summarize why it stopped, how long it ran, how many
  iterations it used, and the recent timings.
- Treat `completed`, `cancelled`, `max_iterations_reached`, and `corrupted` as
  terminal statuses.
- If the current session has no loop but other sessions do, mention the other
  session ids without taking action on them.
- Use the current-session cancel command by default:

```bash
bash ~/.codex/plugins/easy-loop/scripts/cancel.sh
```

- Use cross-session cancellation only when the user explicitly targets another
  session or asks to force it:

```bash
bash ~/.codex/plugins/easy-loop/scripts/cancel.sh --session-id <id> --force
```

## Completion And Safety

- When continuing an active loop with a completion promise, ensure the final
  assistant answer includes a concise summary and then `<promise>...</promise>`.
- Do not emit the promise until it is fully true.
- Keep the final summary short and outcome-focused so the saved state stays easy
  to scan.
- Per-session state lives under `.codex/easy-loop/<session_id>/`.
- Prefer setting `--max-iterations` even when a completion promise exists.
- Remember that the Stop hook compares the emitted promise text against the
  configured promise exactly after normalizing whitespace.
- A session keeps its terminal state on disk; the next `setup.sh` for that same
  session clears the old state before starting a new run.
- Remember that the Stop hook increments the iteration only when the run
  continues; it terminates immediately on an exact promise match or after
  reaching `max_iterations`.

## Fit

- Good fits: tasks with a clear finish condition, work that can be verified by
  tests or lint, and tight bug-fix loops where repeated attempts are useful.
- Bad fits: ambiguous design work, tasks that need frequent human product
  decisions, and anything where "done" is inherently subjective.
