# llm-dev-sandbox: Project Overview

A persistent, local-first sandbox for running autonomous LLM agents (Claude Code, Gemini CLI) against your real host services, with safety isolation provided by Docker + git worktrees + tmux. This document is the canonical reference for *how the pieces fit together*; for narrower topics see the other files in `docs/`.

## Why This Exists

Running autonomous LLM agents directly on your host is risky: a hallucinated `rm -rf` or wrongly-confident `kubectl delete` can ruin your day. This sandbox provides:

1. A **containment layer** (Docker) so destructive commands hit a container, not the host.
2. A **multi-agent orchestrator** (tmux + worktrees) so multiple agents work in parallel without stepping on each other's files.
3. **Identity passthrough** (mounted `~/.claude`, `~/.ssh`, `~/.config/gh`) so the agent inherits your auth without re-login or copying secrets.

## Architecture at a Glance

```
+----------------------------------------------------------------+
|  tmux session: llm-<project-basename>                           |
|                                                                |
|  +---------------+  +-------------+  +-------------+           |
|  | window 1      |  | window 2    |  | window 3    |   ...     |
|  | "coordinator" |  | "iss-42"    |  | "iss-57"    |           |
|  | gemini OR     |  | sandbox.sh  |  | sandbox.sh  |           |
|  | claude        |  | -> claude   |  | -> claude   |           |
|  | (host shell)  |  | (in docker) |  | (in docker) |           |
|  +-------+-------+  +------+------+  +------+------+           |
|          | provisions       | watches             | watches    |
|          v                  v                     v            |
|  +-------+----------+  +----+----------+   +-----+----------+  |
|  | main repo        |  | wt-issue-42   |   | wt-issue-57    |  |
|  | (host fs)        |  | (worktree)    |   | (worktree)     |  |
|  |                  |  | .swarm/tasks/ |   | .swarm/tasks/  |  |
|  +------------------+  +---------------+   +----------------+  |
+----------------------------------------------------------------+
```

- **Coordinator** lives on the host (not containerized) so it can `tmux new-window`, `git worktree add`, and `gh` against your auth directly.
- **Workers** live inside `llm-sandbox:latest` Docker containers (via `sandbox.sh`) so any destructive command they invent is blast-radius-limited.

## Components

### `sandbox.sh` — Docker wrapper for one agent

Generalized launcher: `sandbox.sh <project-dir> <agent> [extra-args]`

- `<agent>` ∈ `{claude, gemini, listener, bash}` (default `bash`).
- Mounts: project dir (rw), `~/.claude` (rw), `~/.claude.json` (rw), `~/.ssh` (ro), `~/.gitconfig` (ro), `~/.config/gh` (ro), `~/.npm-global` (rw), `~/.npm` (rw), and the script's own dir (ro, so worker-listener.sh is reachable).
- Auto-mounts the **git common dir** when invoked on a worktree whose `.git` file points outside the project dir.
- **Docker-out-of-Docker (DooD):** mounts `/var/run/docker.sock` so Testcontainers / `docker` CLI work inside the sandbox; `--group-add` gives the sandbox user write perms on the socket.
- **GH token passthrough:** reads `gh auth token` on the host and injects as `GH_TOKEN` (necessary because `gh` stores its token in the system keyring on Linux, not in the mounted config dir).
- **SSH agent forwarding** when `SSH_AUTH_SOCK` is set.
- `EXTRA_MOUNTS` env var: comma-separated `host:container[:ro|:rw]` extra bind mounts.
- `.sandbox-env` file in the project dir is auto-loaded as a Docker `--env-file`.
- Networking: `--network host` (so agents can reach `localhost:5432` Postgres, etc.).

### `llm-start.sh` — Bootstrap a Coordinator session

Creates `tmux` session `llm-<basename-of-cwd>` if missing, opens window 1 as `coordinator`, and launches the configured coordinator command in headless print mode (`-p`) with the initial prompt and the system prompt from `COORDINATOR_SYSTEM_PROMPT.md`.

#### Session reuse: detect-dead-coordinator

When the session already exists, `llm-start.sh` inspects the coordinator pane's current command (`tmux list-panes -F '#{pane_current_command}'`) and decides:

- **Idle pane** (bash/zsh/sh) → previous coordinator already exited. **Reuses the existing window** and sends the new prompt into it. Same scrollback, no need to kill anything.
- **Busy pane** (node/claude/etc.) → coordinator is mid-run. Doesn't disturb; just attaches.
- **No session** → creates fresh.

This means you can re-invoke `llm-start.sh` repeatedly with new prompts without thinking about state cleanup.

#### Env vars

| Variable                  | Default            | Notes                                                                                            |
|---------------------------|--------------------|--------------------------------------------------------------------------------------------------|
| `COORDINATOR_CMD`         | `gemini`           | `gemini`, `claude`, or any custom CLI                                                            |
| `COORDINATOR_MODEL`       | `gemini-2.5-flash` | Only consumed when `COORDINATOR_CMD=gemini`. Stable; `gemini-3-flash-preview` is broken on multi-tool sequences (server-side INVALID_ARGUMENT). |
| `COORDINATOR_VERBOSE`     | `0`                | When `1` and using gemini: swaps `-p` for `-i` (`--prompt-interactive`) so tool calls are visible live in the pane. Agent stays alive — exit with `/quit`. claude is unaffected (its `-p` already streams). |
| `COORDINATOR_USE_API_KEY` | `0`                | When `1` and using claude: keeps `ANTHROPIC_API_KEY` in the agent's env (bills the API account). Default strips it so Claude Max OAuth is used. |
| `NON_INTERACTIVE`         | `0`                | When `1`, skip auto-attach (used by tests)                                                       |

#### Auto-discovery

- **`GEMINI_API_KEY`**: when not in environment, walks `$PWD/.env` → `~/.gemini/.env` → `llm-dev-sandbox/.env` → `/opt/work/sysadmin/.env` and sources the first match. Propagated into the tmux session env via `tmux new-session -e` so the coordinator pane inherits it without a per-project `.env` copy.
- **Claude OAuth**: just works via the mounted `~/.claude/` config — no env vars needed. If `ANTHROPIC_API_KEY` *is* set, a warning is printed and the variable is stripped from the coordinator's env (override with `COORDINATOR_USE_API_KEY=1` to bill the API instead of the Max plan).

#### Coordinator command construction (claude path)

- The system prompt is injected via `--append-system-prompt "$(cat $SYSTEM_PROMPT_FILE)"` (claude-code's equivalent of gemini's `GEMINI_SYSTEM_MD`).
- `--dangerously-skip-permissions` is passed (matches gemini's `--yolo` semantics for autonomous operation).

### `setup.sh` — Host-side post-install setup

Idempotent script that fixes one known host-side issue: the npm-published `@google/gemini-cli` package omits its bundled ripgrep binary, but gemini's runtime still probes for it at `<pkg>/bundle/vendor/ripgrep/rg-<plat>-<arch>` and logs `Ripgrep is not available. Falling back to GrepTool.` when missing. `setup.sh` symlinks the system's `/usr/bin/rg` into the path gemini expects.

Run once after install, and again after any `npm i -g @google/gemini-cli` upgrade. The Dockerfile applies the equivalent fix at image-build time, so workers don't need this.

### `.swarm-policy.md` — Per-project rules-of-engagement (optional)

Drop a `.swarm-policy.md` file at the root of any project to give the coordinator binding constraints for *that project's* workers. The coordinator reads it on every wake and embeds the contents verbatim at the top of every worker's task brief under a `## Project Guardrails (MUST OBEY)` header.

Free-form markdown — typical contents include:
- PR rules (`workers may only push branches`, `PR titles must include [swarm]`, etc.)
- File-modification denylist (`do not touch Dockerfile / flyway/** / secrets/** / .env*`)
- Tool-use denylist (`no gradle *release*`, `no kubectl/terraform/aws`, `no DB migrations`)
- Concurrency caps (`max 1 active worker per worktree`)
- Communication rules (`stop and ask in pane on real ambiguity, don't guess`)

A starter is in [`examples/swarm-policy.md.example`](../examples/swarm-policy.md.example) — copy to your project root, edit, commit. Per-project means your monorepo can have stricter rules than your scratch repo.

If the file is absent, the coordinator omits the Guardrails section entirely (no fabricated rules).

### `coordinator-watch.sh` — Event-driven coordinator wake-ups

Long-running daemon that watches every worker's `.swarm/tasks/done/` directory under a project. When a new outcome JSON appears (i.e. a worker finished a task), wakes the coordinator via `llm-start.sh` so it can triage / re-dispatch / merge / etc. Together with the queued protocol, this delivers the **event-driven coordinator** option from the README's "Automating the loop" section without rewriting the agent itself.

```bash
# default — watches $PWD, debounces 30s, blocks on Ctrl-C
coordinator-watch.sh

# in another project
coordinator-watch.sh /opt/work/myproject

# preview without actually waking the coordinator
DRY_RUN=1 coordinator-watch.sh

# exit after the first wake (useful for testing)
ONCE=1 coordinator-watch.sh
```

**Backends (auto-detected):**

| Backend | Latency | Setup |
|---|---|---|
| `inotifywait` (preferred) | instant | `sudo apt install inotify-tools` (and bump `fs.inotify.max_user_watches` for large repos) |
| polling `find` (fallback) | `POLL_SECS=2` (default) | none — works out of the box |

**Env vars:**

| Var | Default | Notes |
|---|---|---|
| `DEBOUNCE_SECS` | `30` | Coalesce N events into 1 wake when many workers finish near-simultaneously |
| `DRY_RUN` | `0` | Log triggers without invoking llm-start.sh |
| `ONCE` | `0` | Exit after first wake — for smoke-tests |
| `LLM_START` | `/opt/work/sysadmin/llm-dev-sandbox/llm-start.sh` | Override path |
| `WAKE_PROMPT` | (status-triage prompt; read-only) | What the coordinator does when woken |
| `POLL_SECS` | `2` | Polling interval (polling backend only) |

**Anti-runaway:** the default `WAKE_PROMPT` is read-only ("triage … decide next actions … do NOT dispatch new workers unless the user asked you to") and `DEBOUNCE_SECS` ensures back-to-back finishes don't N+1-loop the coordinator. Override `WAKE_PROMPT` if you want to hand more autonomy to the watcher.

### `coordinator-error-tail.sh` — Surface gemini API errors in the pane

Called automatically by `llm-start.sh` immediately after every gemini invocation. Checks for `/tmp/gemini-*-error-*.json` files modified in the last minute and decodes the nested `.error.message` (gemini's API errors are double-encoded JSON) into the pane.

Without this, gemini-cli truncates server-side errors to `Operation cancelled.[ERROR] Operation cancelled.` while writing the real cause to `/tmp` — users had to know to check there. With it, the actual error (e.g., `INVALID_ARGUMENT: Please ensure that function response turn comes immediately after a function call turn.`) is visible in the same pane.

No-op for the claude path: claude's `-p` already streams errors and tool calls directly.

### `worker-listener.sh` — Queue watcher for worker agents

Runs inside the worker sandbox. Polls every 2 seconds for new tasks. Two protocols supported:

**v2 queue (preferred)** — per-worktree directory tree:

```
<worktree>/.swarm/tasks/
  inbox/        coordinator writes <id>.md here (atomic mktemp+mv)
  processing/   listener mv on pickup (atomic claim — wins race if multiple listeners)
  done/         listener mv when finished + writes <id>.{ok,err}.json
```

`done/<id>.{ok,err}.json` is a structured outcome record the coordinator can poll without scraping the pane:

```json
{
  "task_id": "20260504-031415-1234",
  "started":  "2026-05-04T03:14:15Z",
  "finished": "2026-05-04T03:18:42Z",
  "duration_seconds": 267,
  "exit_code": 0,
  "outcome": "ok",
  "agent": "claude",
  "model": null,
  "headless": false
}
```

**v1 single-file (legacy, still supported)** — `.agent-task.md` → `.agent-task-last.md`. No structured outcome.

The listener checks v2 inbox first, falls back to v1. Both can be in use simultaneously (mid-migration). New work should use v2.

#### Listener loop, per task:

1. **Claim** via atomic `mv` (v2) or rename (v1).
2. **Echo brief** (first 40 lines) to the pane so attached observers see what's running.
3. **Dispatch** the configured agent (default claude, override via `WORKER_CMD`; default model from the agent's CLI, override via `WORKER_MODEL`).
4. **Archive + record** — move brief to `done/` (v2) or `.agent-task-last.md` (v1); for v2 also write `done/<id>.{ok,err}.json` with timing + exit code.
5. **Loop** back for the next task.

#### Worker mode

| Mode                  | Agent flags                                | Lifecycle                                                                                                  |
|-----------------------|--------------------------------------------|------------------------------------------------------------------------------------------------------------|
| **interactive** (default) | `claude "$TASK"` / `gemini -i "$TASK"` | Runs prompt + tools, drops to REPL. User attaches to interact / answer questions / `/quit` when done.       |
| **headless** (`WORKER_HEADLESS=1`) | `claude -p "$TASK"` / `gemini -p "$TASK"` | Prints output and exits. Skips claude's "Trust this folder?" dialog. Used by e2e tests and any automation. |

#### Worker env vars (threaded through `caller → llm-start.sh → tmux session env → sandbox.sh -e → container env`)

| Variable              | Default          | Notes                                                                                       |
|-----------------------|------------------|---------------------------------------------------------------------------------------------|
| `WORKER_CMD`          | `claude`         | Switches the worker's LLM CLI (e.g. `gemini` for fallback when claude Max is capped).       |
| `WORKER_MODEL`        | (CLI default)    | Passed as `--model` (claude) or `-m` (gemini). E.g. `sonnet`, `gemini-2.5-flash`.            |
| `WORKER_HEADLESS`     | `0`              | When `1`, run agent with `-p` (print + exit). Required when no human is attached.           |

This decouples the coordinator from the workers: the coordinator just drops a markdown file into the worktree and the worker picks it up asynchronously.

### `COORDINATOR_SYSTEM_PROMPT.md` — Coordinator's brain

Defines the coordinator's startup checklist (read `.swarm-policy.md` → `git status` → `gh issue list` → backlog grooming → provision up to 3 workers) and the exact shell commands for spawning a worker:

```bash
git worktree add ../wt-issue-42 -b fix/issue-42
tmux new-window -d -n "iss-42" "/opt/work/sysadmin/llm-dev-sandbox/sandbox.sh ../wt-issue-42 listener"
echo "Fix issue #42. Details: $(gh issue view 42)" > ../wt-issue-42/.agent-task.md
```

Note the `tmux new-window -d` — workers spawn *in the background* so they don't steal focus.

### `test-shape-swarm.sh` — Non-LLM shape test for the queue protocol

Deterministic regression coverage for `worker-listener.sh` that doesn't burn LLM tokens or require auth. Uses the listener's `bash` fallback agent (executed when AGENT is neither `claude` nor `gemini`) to make task briefs runnable shell commands; assertions then check files produced by those briefs.

Covers:
- v2 happy path: atomic-write to `inbox/`, brief archives to `done/`, `.ok.json` written with full schema validation
- v2 failure path: non-zero exit produces `.err.json` with the right `exit_code` and `outcome`
- v1 legacy: `.agent-task.md` → `.agent-task-last.md`, no spurious JSON
- Lex ordering: 3 v2 tasks processed in queue order
- `.tmp.*` exclusion: in-flight atomic-write filenames must not be claimed

Runs in seconds. Pair with `test-e2e-swarm.sh` for full claude/gemini path coverage when you have auth + want to validate the LLM end too. Use `KEEP=1` to retain the temp dir for inspection.

### `test-e2e-swarm.sh` — Local end-to-end test (with real LLM)

Spins up `/tmp/swarm-e2e-<epoch>/main-repo` as a fresh git repo, copies the project's `.env` (so the coordinator inherits `GEMINI_API_KEY`), and invokes `llm-start.sh` with a hardcoded prompt that asks the coordinator to:

1. Create two worktrees (`../wt-alpha`, `../wt-beta`).
2. Spawn a worker listener in each via `tmux new-window`.
3. Drop `.agent-task.md` in each instructing the worker to write `alpha-success.txt` / `beta-success.txt`.

Then polls those marker files for up to 90 seconds, with stuck-detection (kills the session if the coordinator pane stops changing for 60s) and error detection (`grep -iE 'error|exception|missing API key|...'`).

Set `KEEP_ALIVE=1` to leave the tmux session running on success/timeout for inspection.

`COORDINATOR_CMD=claude ./test-e2e-swarm.sh` runs the same test using your Claude Max plan instead of the Gemini free tier — useful when the gemini daily quota is exhausted.

## End-to-End Flow (Real Use)

1. `cd /opt/work/myproject`
2. `./llm-start.sh` (or `COORDINATOR_CMD=claude ./llm-start.sh` to use Max).
3. Coordinator wakes, runs `gh issue list`, picks unassigned issues, provisions worktrees + worker windows.
4. Workers (claude, in docker) read `.agent-task.md`, do the work, push a branch, open a PR via `gh`.
5. You attach with `tmux a -t llm-myproject` to watch / intervene.

## Coordinator Trade-offs

| Coordinator           | Pros                                                                          | Cons                                                                |
|-----------------------|-------------------------------------------------------------------------------|---------------------------------------------------------------------|
| `gemini` (free tier)  | $0; large context; fast for simple orchestration                              | 20 req/min, 1500/day — burns quickly during multi-agent swarms      |
| `gemini` (paid tier)  | Higher rate limits (~360 req/min); same model strengths                       | Pay-as-you-go API billing                                           |
| `claude` (Max OAuth)  | No per-request billing under Max plan; strong tool use                        | Subject to Max-plan rolling 5-hour usage caps                       |
| `claude` (API key)    | Highest reliability, paid                                                     | Pay-per-token; the script *strips* the API key by default — opt-in  |

## Coordinator Lifecycle (one-shot by design)

The coordinator runs in `-p` headless mode: each `llm-start.sh` invocation wakes it, the agent reads disk state (`git`, `gh`, worktrees), takes its action, and exits. There is no resident supervisor process. This is deliberate — see the README's "How the coordinator works" section for the rationale and the three upgrade paths (cron, event-driven, interactive) when you outgrow it.

The disk *is* the coordinator's memory across invocations: worktrees, branches, open PRs, `.agent-task-last.md` archives. Any new wake re-derives state from that.

## Known Limitations

- ripgrep symlink (host) survives gemini-cli upgrades only if you re-run `setup.sh`. The Dockerfile applies the same fix at image-build time, so workers are immune.

## Reproducible Builds

The `Dockerfile` pins all upstream-version-sensitive tools via `ARG`-driven version strings near the top:

| ARG | Default | Notes |
|---|---|---|
| `NODE_MAJOR` | `22` | Major only — NodeSource ships stable patches inside a major. |
| `CLAUDE_CODE_VERSION` | `2.1.126` | Bump after testing — claude-code minor releases occasionally rename CLI flags. |
| `GEMINI_CLI_VERSION` | `0.40.1` | Bump cautiously — gemini-cli's tool-call protocol has changed across versions. |
| `OPENAI_CODEX_VERSION` | `0.128.0` | Less load-bearing — we don't currently script against it. |
| `PROMPTFOO_VERSION` | `0.121.9` | Same. |
| `DENO_VERSION` | `2.7.14` | Pinned via positional arg to `deno.land/install.sh`. |
| `UV_VERSION` | `0.11.8` | Pinned via direct GitHub release tarball (astral's `install.sh` ignores `UV_VERSION` env, so we bypass it). |

Apt-managed tools (Java, ripgrep, gh, docker-cli) are intentionally NOT pinned to dpkg version strings — too fragile for a personal sandbox. Major versions are still pinned via package selection (`openjdk-21`, `setup_22.x`).

**Upgrade workflow:**
```bash
# Find the current latest of any pinned tool
npm view @anthropic-ai/claude-code version
curl -s https://api.github.com/repos/astral-sh/uv/releases/latest | jq -r .tag_name

# Bump the ARG in Dockerfile, OR override at build time:
docker build --build-arg CLAUDE_CODE_VERSION=2.2.0 -t llm-sandbox:latest .

# Test the e2e suite to confirm nothing regressed:
./test-e2e-swarm.sh
```

- `gemini-3-flash-preview` (and possibly other preview models) hit a server-side `400 INVALID_ARGUMENT` on multi-tool-call sequences — which is exactly the coordinator's workload. Stick to `gemini-2.5-flash` (the default) until Google fixes the preview tier.
- ripgrep symlink (host) survives gemini-cli upgrades only if you re-run `setup.sh`. Add to your shell rc or a post-`npm-i` hook if you upgrade often.

## Related Files

- [`./architecture.md`](./architecture.md) — design philosophy, comparison to CrewAI / LangGraph / Composio AO.
- [`./advanced-usage.md`](./advanced-usage.md) — manual worktrees, Testcontainers, custom mounts.
- [`./security.md`](./security.md) — `--yolo`/`--dangerously-skip-permissions` blast radius.
- [`./troubleshooting.md`](./troubleshooting.md) — SSH, `gh` auth, networking issues.
