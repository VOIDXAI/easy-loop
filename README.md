# Easy Loop for Codex

`easy-loop` is an official-layout personal Codex plugin plus Stop-hook
bootstrap that turns Codex into a persistent iterative loop runner for the
current repo.
Temporary test text for Easy Loop smoke verification.

## What It Does

- Persists per-session loop state under `.codex/easy-loop/<session_id>/`
- Uses a Codex `Stop` hook to intercept normal completion
- Replays the same prompt until either:
  - a truthful `<promise>...</promise>` is emitted
  - `--max-iterations` is reached
  - the loop is cancelled

## Requirements

- Codex CLI with plugin support
- `bash`
- `jq`
- `perl`
- `python3`
- `git` for `--repo-url` installs
- macOS, Linux, or WSL

## Install From A Local Clone

```bash
git clone <your-repo-url> ~/.codex/plugins/easy-loop
bash ~/.codex/plugins/easy-loop/install.sh
```

If you are working from an unpublished local checkout, you can run the installer
directly from that checkout and let it copy the plugin into
`~/.codex/plugins/easy-loop`:

```bash
bash ./install.sh
```

## Install Via A Bootstrap Script

After publishing this repo, a one-line install can use the raw `install.sh` plus
the git repo URL:

```bash
curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/install.sh | \
  bash -s -- --repo-url https://github.com/<owner>/<repo>.git
```

## Start A Loop

The recommended path is to mention `$easy-loop` in Codex and let the skill
guide the setup for the current session. When the current Codex runtime exposes
`request_user_input`, the skill should use it for compact action and option
pickers. When that tool is not available in the current mode or client, the
skill should fall back to short plain-text questions. In both cases it should
ask only for missing details, generate a compact startup draft from the task
plus any inferred scope or finish condition, let the user confirm or tweak that
draft, recommend `max-iterations` when it can estimate the workload, fall back
to `20` only when it cannot estimate responsibly, generate a unique completion
promise, and then call `setup.sh`.

### Complete Skill Example

The skill treats the three forms below as different actions:

- `$easy-loop <task goal>` starts a loop
- `$easy-loop status` reports the current session's loop status
- `$easy-loop cancel` cancels the current session's active loop

Example conversation in a Codex session:

```text
User:
$easy-loop Update README.md with a complete skill-trigger example, then run bash tests/smoke.sh until it passes.

Codex:
Here is the startup draft I would use:
- task: Update README.md with a complete skill-trigger example
- acceptance: README.md documents start, status, and cancel, and bash tests/smoke.sh passes
- finish condition: docs updated and smoke test passing
- recommended max-iterations: 5
- completion promise: README_SKILL_EXAMPLE_AND_SMOKE_PASS

Reply with confirm to start Easy Loop with this draft, or send adjustments. I
have not started the loop yet, and I will not call setup.sh until you confirm.

User:
Confirm. Start the loop with that draft.

Codex:
I am starting the loop in this repo with:
bash ~/.codex/plugins/easy-loop/scripts/setup.sh \
  "Update README.md with a complete skill-trigger example, then run bash tests/smoke.sh until it passes." \
  --max-iterations 5 \
  --completion-promise "README_SKILL_EXAMPLE_AND_SMOKE_PASS"

Easy Loop activated.
Session directory: .codex/easy-loop/019d2e0c-05a0-7fc2-9550-256dc58e2ca8
State file: .codex/easy-loop/019d2e0c-05a0-7fc2-9550-256dc58e2ca8/state.md
Iterations file: .codex/easy-loop/019d2e0c-05a0-7fc2-9550-256dc58e2ca8/iterations.jsonl
Iteration: 1
Max iterations: 5
Completion promise: README_SKILL_EXAMPLE_AND_SMOKE_PASS
Session id: 019d2e0c-05a0-7fc2-9550-256dc58e2ca8

Later, in the same Codex session:
User:
$easy-loop status

Codex:
Current status: active
Current iteration: 2 of 5
State file: .codex/easy-loop/019d2e0c-05a0-7fc2-9550-256dc58e2ca8/state.md
Iterations file: .codex/easy-loop/019d2e0c-05a0-7fc2-9550-256dc58e2ca8/iterations.jsonl
Recent per-iteration timings:
- iteration 1: continued (18342 ms)

If you need to stop early in that same session:
User:
$easy-loop cancel

Codex:
I ran:
bash ~/.codex/plugins/easy-loop/scripts/cancel.sh

Cancelled the active Easy Loop for session 019d2e0c-05a0-7fc2-9550-256dc58e2ca8.
Easy Loop summary.
Session id: 019d2e0c-05a0-7fc2-9550-256dc58e2ca8
Status: cancelled
Iteration records: 2
Completion promise: README_SKILL_EXAMPLE_AND_SMOKE_PASS
Per-iteration:
  - iteration 1: continued (18342 ms)
  - iteration 2: cancelled (9411 ms)
```

A bare `$easy-loop` is not enough to start a new loop by itself. Without an
existing on-disk session state, the skill should ask the user to reply with one
of `$easy-loop status`, `$easy-loop cancel`, or `$easy-loop <task goal>`. If
the current session already has Easy Loop state on disk, the skill should
inspect that state before suggesting a restart.

If you want to start a loop manually from the shell, run:

From the repo you want Codex to work on:

```bash
export CODEX_THREAD_ID=<current-codex-session-id>
bash ~/.codex/plugins/easy-loop/scripts/setup.sh \
  "Fix the failing test suite and stop only when every test passes." \
  --max-iterations 20 \
  --completion-promise "TEST_SUITE_GREEN"
```

`setup.sh` requires `CODEX_THREAD_ID`, so manual startup must happen from the
active Codex session that owns the loop. If you omit `--max-iterations`,
`setup.sh` leaves the loop unlimited; the `20` above is only an example value,
not a hardcoded runtime default.

Each Codex session gets its own state directory:

- `.codex/easy-loop/<session_id>/state.md`
- `.codex/easy-loop/<session_id>/iterations.jsonl`

That allows multiple Codex sessions in the same repo to run independent Easy
Loop sessions without touching each other.

Then keep working in the same Codex session. The Stop hook will continue the
loop automatically.

To inspect status later, use `$easy-loop status` in that session. The skill
should read the current session's state and history before suggesting any
restart. If the user later sends a bare `$easy-loop` and the current session
already has state on disk, the skill should inspect status first before
suggesting a new loop.

Note: in OpenAI's open-source Codex codebase, the structured interaction
capability is named `request_user_input`. Availability can vary by collaboration
mode and runtime configuration, so the plugin should degrade gracefully instead
of assuming it always exists.

## Cancel A Loop

```bash
bash ~/.codex/plugins/easy-loop/scripts/cancel.sh
```

Force-cancel:

```bash
bash ~/.codex/plugins/easy-loop/scripts/cancel.sh --force
```

Cancel another Codex session's loop explicitly:

```bash
bash ~/.codex/plugins/easy-loop/scripts/cancel.sh --session-id <session-id> --force
```

## Installed Paths

- plugin source: `~/.codex/plugins/easy-loop`
- plugin marketplace: `~/.agents/plugins/marketplace.json`
- Codex config: `~/.codex/config.toml`
- Codex hooks: `~/.codex/hooks.json`
- plugin cache: `~/.codex/plugins/cache/<marketplace>/easy-loop/local`
- marketplace source path: `./.codex/plugins/easy-loop`

## Notes

- The on-disk plugin layout follows the official personal plugin docs: plugin
  source under `~/.codex/plugins/` and marketplace entries under
  `~/.agents/plugins/marketplace.json`.
- The installer enables `features.plugins = true` and
  `features.codex_hooks = true`.
- The installer also enables the plugin in `config.toml` and installs it into
  the Codex plugin cache so it is immediately usable.
- The plugin is the distribution layer. Easy Loop still depends on a
  separate `Stop` hook in `hooks.json`, because hooks are not part of the
  documented plugin component set yet.
- New loops write per-session state to `.codex/easy-loop/<session_id>/`.
- Terminal state is preserved on disk so the current session can inspect its
  last run; the next `setup.sh` for that same session clears the previous run
  before starting a new one.
- Active loops are isolated by `session_id`, so multiple Codex sessions can use
  Easy Loop in the same repo at once.
- `20` is only a skill-layer fallback recommendation when the workload cannot be
  estimated responsibly; it is not the runtime default in `setup.sh`.
- The completion promise must only be emitted when it is fully true.
- Always prefer setting `--max-iterations` even when a completion promise
  exists.
- Before publishing to GitHub, update `.codex-plugin/plugin.json` with your
  final project metadata if you want marketplace-ready branding fields.

## Validate Locally

Run the smoke test to verify install, hook behavior, cancellation, and uninstall
in an isolated temporary home:

```bash
bash tests/smoke.sh
```

GitHub Actions runs the same smoke test on pushes and pull requests.
