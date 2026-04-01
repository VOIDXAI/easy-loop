# Easy Loop for Codex

`easy-loop` is an official-layout personal Codex plugin plus Stop-hook
bootstrap that turns Codex into a persistent iterative loop runner for the
current repo.

## What It Does

- Persists per-session loop state under `.easy-loop/<tag>/`
- Uses a Codex `Stop` hook to intercept normal completion
- Replays the same prompt until either:
  - a truthful `<promise>...</promise>` is emitted
  - `--max-iterations` is reached
  - the loop is cancelled

## Quick Start

### Requirements

- Codex CLI with plugin support
- `bash`
- `jq`
- `perl`
- `python3`
- `git` for `--repo-url` installs
- macOS, Linux, or WSL

### Install from a local clone

```bash
git clone https://github.com/VOIDXAI/easy-loop.git ~/.codex/plugins/easy-loop
bash ~/.codex/plugins/easy-loop/install.sh
```

If you are working from an unpublished local checkout, you can run the installer
directly from that checkout and let it copy the plugin into
`~/.codex/plugins/easy-loop`:

```bash
bash ./install.sh
```

### Install via a bootstrap script

```bash
curl -fsSL https://raw.githubusercontent.com/VOIDXAI/easy-loop/main/install.sh | \
  bash -s -- --repo-url https://github.com/VOIDXAI/easy-loop.git
```

### Start a loop

In a Codex session, ask for a concrete task with `$easy-loop <task goal>`.

```text
$easy-loop Update README.md with a complete skill-trigger example, then run bash tests/smoke.sh until it passes.
```

The shortest path is:
- ask for a concrete task with `$easy-loop <task goal>`
- confirm the generated startup draft
- let Easy Loop keep iterating in the same Codex session

For the full behavior around `request_user_input`, startup drafts, completion
promises, and `max-iterations`, see the detailed example below.

### Check status

```text
$easy-loop status
```

### Cancel the loop

```text
$easy-loop cancel
```

## How It Works

Easy Loop combines four parts:

1. **The plugin / skill layer** interprets `$easy-loop ...` requests.
2. **`setup.sh`** creates per-session state and activates the loop.
3. **The Codex `Stop` hook** intercepts normal completion.
4. **Session state on disk** decides whether to continue, stop, or cancel.

A simplified flow looks like this:

```text
User task
  -> Codex skill/plugin
  -> setup.sh
  -> .easy-loop/<tag>/state.md
  -> Codex works on the repo
  -> Stop hook fires on normal completion
  -> Easy Loop checks promise / iteration budget / cancel state
  -> continue same prompt or stop cleanly
```

Each Easy Loop run gets its own state directory:

- `.easy-loop/<tag>/state.md`
- `.easy-loop/<tag>/iterations.jsonl`

Easy Loop still tracks the owning Codex session through the `session_id`
frontmatter inside `state.md`, so multiple Codex sessions in the same repo can
run independent loops without touching each other.

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
Session directory: .easy-loop/update-readme-md-with-a-complete-skill-trigger
State file: .easy-loop/update-readme-md-with-a-complete-skill-trigger/state.md
Iterations file: .easy-loop/update-readme-md-with-a-complete-skill-trigger/iterations.jsonl
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
State file: .easy-loop/update-readme-md-with-a-complete-skill-trigger/state.md
Iterations file: .easy-loop/update-readme-md-with-a-complete-skill-trigger/iterations.jsonl
Recent per-iteration timings:
- iteration 1: continued (18342 ms)

If you need to stop early in that same Codex session:
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

## Manual shell startup

If you want to start a loop manually from the shell, run this from the repo you
want Codex to work on:

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

Then keep working in the same Codex session. The Stop hook will continue the
loop automatically.

To inspect status later, use `$easy-loop status` in that session. The skill
should read the current session's state and history before suggesting any
restart. If the user later sends a bare `$easy-loop` and the current session
already has state on disk, the skill should inspect status first before
suggesting a new loop.

## Troubleshooting

### `CODEX_THREAD_ID` is missing

Most likely cause: manual startup is happening outside the active Codex session
that owns the loop.

First check:
- confirm you are launching `setup.sh` from the intended Codex session
- confirm `CODEX_THREAD_ID` is exported in that shell before starting the loop

### The plugin seems installed but Easy Loop is not available

Most likely cause: plugin install completed, but Codex config / marketplace /
cache state is incomplete or stale.

First check:
- rerun `install.sh`
- inspect `~/.codex/config.toml`
- inspect `~/.agents/plugins/marketplace.json`
- inspect the plugin cache under `~/.codex/plugins/cache/`

### The hook is not firing

Most likely cause: Codex hooks are not enabled, or `hooks.json` was not updated
as expected.

First check:
- inspect `~/.codex/hooks.json`
- confirm `features.codex_hooks = true`
- rerun the smoke test to validate hook behavior end-to-end

### `request_user_input` is unavailable

Most likely cause: the current Codex collaboration mode or runtime does not
expose structured interaction tools.

Expected behavior:
- Easy Loop should degrade gracefully to short plain-text prompts instead of
  assuming structured interaction is always available

### Status exists on disk, but the loop is not active

Most likely cause: the last run ended normally, hit max iterations, or was
cancelled, and the session state was intentionally preserved for inspection.

First check:
- inspect `.easy-loop/<tag>/state.md`
- inspect `.easy-loop/<tag>/iterations.jsonl`
- start a fresh loop only after confirming the old state is terminal

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

## Compatibility

Easy Loop currently assumes:

- macOS, Linux, or WSL
- a shell environment with `bash`, `jq`, `perl`, `python3`, and `git`
- Codex plugin support is available
- Codex hooks are available and enabled
- some Codex runtimes may expose `request_user_input`, but the plugin should
  not depend on it unconditionally

Note: in OpenAI's open-source Codex codebase, the structured interaction
capability is named `request_user_input`. Availability can vary by collaboration
mode and runtime configuration, so the plugin should degrade gracefully instead
of assuming it always exists.

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
- The plugin is the distribution layer. Easy Loop still depends on a separate
  `Stop` hook in `hooks.json`, because hooks are not part of the documented
  plugin component set yet.
- New loops write per-session state to `.easy-loop/<tag>/`.
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
- If you fork or rebrand this project, update `.codex-plugin/plugin.json` with
  your own marketplace metadata before republishing it.

## Validate Locally

Run the smoke test to verify install, hook behavior, cancellation, and uninstall
in an isolated temporary home:

```bash
bash tests/smoke.sh
```

GitHub Actions runs the same smoke test on pushes and pull requests.

## License

MIT. See `LICENSE`.
