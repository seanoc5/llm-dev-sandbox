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
|  |                  |  | .agent-task.md|   | .agent-task.md |  |
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

Env vars:

| Variable             | Default                         | Notes                                                          |
|----------------------|---------------------------------|----------------------------------------------------------------|
| `COORDINATOR_CMD`    | `gemini`                        | `gemini`, `claude`, or any custom CLI                          |
| `COORDINATOR_MODEL`  | `gemini-3-flash`                | Only consumed when `COORDINATOR_CMD=gemini`                    |
| `NON_INTERACTIVE`    | `0`                             | When `1`, skip auto-attach (used by tests)                     |

When `COORDINATOR_CMD=claude`:

- `ANTHROPIC_API_KEY` is **stripped from the launched coordinator's env** (`env -u ANTHROPIC_API_KEY claude …`). This forces use of the Claude Max OAuth session stored in `~/.claude/`. A warning is printed if the variable was set, so you don't silently start billing your API account when you intended to use the Max plan.
- The system prompt is injected via `--append-system-prompt "$(cat $SYSTEM_PROMPT_FILE)"` (claude-code's equivalent of gemini's `GEMINI_SYSTEM_MD`).
- `--dangerously-skip-permissions` is passed (matches gemini's `--yolo` semantics for autonomous operation).

### `worker-listener.sh` — Inbox for worker agents

Runs inside the worker sandbox. Polls every 2 seconds for a `.agent-task.md` file in the cwd. When found:

1. Reads the task into `$TASK`.
2. Renames the file to `.agent-task-last.md` (so it's not re-executed and stays as a debugging artifact).
3. Dispatches to the agent: currently `claude "$TASK" --dangerously-skip-permissions` (hard-coded — see `../todo/TODO.md` for the parameterization task).
4. Loops back to wait for the next task.

This decouples the coordinator from the workers: the coordinator just drops a markdown file into the worktree and the worker picks it up asynchronously.

### `COORDINATOR_SYSTEM_PROMPT.md` — Coordinator's brain

Defines the coordinator's startup checklist (`git status` → `gh issue list` → backlog grooming → provision up to 3 workers) and the exact shell commands for spawning a worker:

```bash
git worktree add ../wt-issue-42 -b fix/issue-42
tmux new-window -d -n "iss-42" "/opt/work/sysadmin/llm-dev-sandbox/sandbox.sh ../wt-issue-42 listener"
echo "Fix issue #42. Details: $(gh issue view 42)" > ../wt-issue-42/.agent-task.md
```

Note the `tmux new-window -d` — workers spawn *in the background* so they don't steal focus.

### `test-e2e-swarm.sh` — Local end-to-end test

Spins up `/tmp/swarm-e2e-<epoch>/main-repo` as a fresh git repo, copies the project's `.env` (so the coordinator inherits `GEMINI_API_KEY`), and invokes `llm-start.sh` with a hardcoded prompt that asks the coordinator to:

1. Create two worktrees (`../wt-alpha`, `../wt-beta`).
2. Spawn a worker listener in each via `tmux new-window`.
3. Drop `.agent-task.md` in each instructing the worker to write `alpha-success.txt` / `beta-success.txt`.

Then polls those marker files for up to 90 seconds, with stuck-detection (kills the session if the coordinator pane stops changing for 15s) and error detection (`grep -iE 'error|exception|missing API key|...'`).

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

- Workers are hard-coded to `claude`; see `todo/TODO.md` for parameterization plan.
- Worker inbox is a single polled file (`.agent-task.md`) with no locking or structured ack — fine for 1 coordinator + 1 worker per worktree, but a 2nd dispatch during execution races. Queued-protocol redesign also in `todo/TODO.md`.
- `GEMINI_API_KEY` is now auto-discovered from `$PWD/.env` → `~/.gemini/.env` → `llm-dev-sandbox/.env` → `/opt/work/sysadmin/.env` by `llm-start.sh`. Claude uses OAuth at `~/.claude/`.

## Related Files

- [`./architecture.md`](./architecture.md) — design philosophy, comparison to CrewAI / LangGraph / Composio AO.
- [`./advanced-usage.md`](./advanced-usage.md) — manual worktrees, Testcontainers, custom mounts.
- [`./security.md`](./security.md) — `--yolo`/`--dangerously-skip-permissions` blast radius.
- [`./troubleshooting.md`](./troubleshooting.md) — SSH, `gh` auth, networking issues.
