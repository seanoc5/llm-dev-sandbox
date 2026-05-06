# LLM Dev Sandbox

A persistent, local-first **convenience-isolation layer** for running LLM agents like **Claude Code**, **Gemini CLI**, and **promptfoo** against your real host services.

Running autonomous LLM agents directly on your host is risky — agents can hallucinate destructive shell commands. This wrapper reduces blast radius for honest mistakes (typos, hallucinated `rm -rf`, wrong cwd) by running the agent inside a Docker container that only has the project dir mounted rw plus the auth state it needs.

> ⚠️ **This is NOT a security boundary against a hostile / compromised agent.**
> The container runs with `--network host`, mounts `/var/run/docker.sock` for Docker-out-of-Docker, mounts `~/.claude` rw and `~/.ssh` ro, and the agents run with `--dangerously-skip-permissions` / `--yolo`. A sufficiently-capable agent inside the container can spawn sibling containers with `-v /:/host`, exfiltrate your gh token, push to your repos, etc. Treat the agents as **trusted-but-fallible**, not as adversaries. See [`docs/security.md`](./docs/security.md) for blast-radius details.

By running locally with `--network host`, the agent can interact with your entire local development environment (e.g., local Postgres, Spring Boot) exactly as you do, without complex tunneling.

---

## Contents

- [Documentation Index](#-documentation-index)
- [Quick Start](#-quick-start)
  - [Prerequisites](#1-prerequisites)
  - [Install](#2-install)
  - [Run Autonomous Swarm (Recommended)](#3-run-autonomous-swarm-recommended)
    - [How the coordinator works](#how-the-coordinator-works)
      - [Automating the loop](#automating-the-loop)
    - [Configuring caps and filters](#configuring-caps-and-filters)
      - [Per-project setup (durable config)](#per-project-setup-durable-config)
      - [One-shot override modes](#one-shot-override-modes)
    - [Live status](#live-status)
  - [Run Manual Sandbox (Single Agent)](#4-run-manual-sandbox-single-agent)
- [Features at a glance](#-features-at-a-glance)

---

## 📚 Documentation Index

For deep-dives into specific topics, please refer to the reference documentation:
- 🏗️ [**Architecture & Orchestration**](./docs/architecture.md) - Learn how the Coordinator -> Worker pattern uses Git worktrees to run multiple agents in parallel.
- ⚙️ [**Advanced Usage**](./docs/advanced-usage.md) - Manual worktree setup, Testcontainers, `.sandbox-env`, and custom bind mounts.
- 🛡️ [**Security Considerations**](./docs/security.md) - Understand the blast radius and the risks of `--yolo` / Docker-out-of-Docker.
- 🚑 [**Troubleshooting**](./docs/troubleshooting.md) - Fix common SSH, `gh` auth, and networking errors.
- 🪟 [**tmux Cheatsheet**](./docs/tmux-cheatsheet.md) - Attach/detach, multi-client handling, capture-pane for diagnostics, and other commands you'll actually use with the swarm.

---

## 🚀 Quick Start

### 1. Prerequisites
- Docker installed and running.
- `gh` CLI authenticated on the host.

### 2. Install
```bash
git clone git@github.com:seanoc5/llm-dev-sandbox.git
cd llm-dev-sandbox
docker build -t llm-sandbox:latest .

# One-time host-side setup (idempotent; re-run after gemini-cli upgrades).
# At the end it prints the recommended LLM_SANDBOX_DIR + PATH exports for
# your shell rc — copy them into ~/.bashrc / ~/.zshrc.
./scripts/setup.sh
```

The clone path is up to you — every script self-locates via `BASH_SOURCE`, so `git clone … && cd … && ./llm-start.sh` works from anywhere. Setting `LLM_SANDBOX_DIR` in your shell rc is only needed when you run scripts from outside the repo or via wrappers that don't preserve the path.

`scripts/setup.sh` symlinks the system `rg` into the path `@google/gemini-cli` looks for (the npm package omits its bundled binary). Without it gemini logs `Ripgrep is not available. Falling back to GrepTool.` on every run and uses a slower built-in matcher.

For tab-completion of `llm-start.sh` flags (and the helper scripts), add this line to your `~/.bashrc`:

```bash
. "$LLM_SANDBOX_DIR/completions/llm-dev-sandbox.bash"
```

`setup.sh` prints this hint at the end of its run.

### 3. Run Autonomous Swarm (Recommended)
Let the coordinator triage your backlog and provision worker agents.

```bash
# Navigate to any project you want to work on
cd /opt/work/myproject

# Bootstrap the coordinator (claude default; COORDINATOR_CMD=gemini to use Gemini)
$LLM_SANDBOX_DIR/llm-start.sh "Optional initial prompt; default: run startup checklist"
```
This creates a dedicated `tmux` session, runs the coordinator in Window 1 with the prompt you supplied (default: survey GitHub issues + provision workers), and spawns isolated Claude worker agents in dockerized git worktrees, one per dispatched issue.

**Common CLI flags** (full list in `./llm-start.sh --help`):

```bash
./llm-start.sh -w                            # one-shot + auto top-up watcher
./llm-start.sh --yolo                        # unattended sprint mode (see --help)
./llm-start.sh --max-workers 8 --watch       # 8 workers with watcher
./llm-start.sh --include-others              # claim teammates' tickets too
./llm-start.sh --target-available 0          # disable auto-issue-creation
./llm-start.sh -h                            # full reference
```

Precedence is the standard chain: **flag > shell env > `<project>/.swarm/.env` > `<sandbox>/.env.example`**. Anything you can do via flag is also doable via env var (and vice-versa for the cap/filter subset). Flags exist for ergonomics; env vars exist for durability + subprocess inheritance.

**Common env-only knobs** (no flag equivalent — set per-invocation or in shell rc):

```bash
# Watch gemini work live (interactive UI in coordinator pane; exit with /quit)
COORDINATOR_VERBOSE=1 ./llm-start.sh "..."

# Use Claude Max instead of gemini (strips ANTHROPIC_API_KEY so OAuth is used)
COORDINATOR_CMD=claude ./llm-start.sh "..."

# Override the gemini model (e.g., A/B-test the preview tier)
COORDINATOR_MODEL=gemini-3-flash-preview ./llm-start.sh "..."
```

Full env-var reference in [`docs/llm-dev-sandbox-overview.md`](./docs/llm-dev-sandbox-overview.md#env-vars).

#### How the coordinator works

The coordinator is a **one-shot triage agent**, not a long-running supervisor daemon:

1. You invoke `llm-start.sh "<what you want done>"` (or no prompt for the default checklist).
2. The coordinator wakes, reads project state (`git`, `gh`), provisions any workers needed, and **exits**.
3. Workers continue asynchronously in their own `tmux` windows — they don't need the coordinator alive to do their work.
4. When you want a status check or another action, **invoke `llm-start.sh` again** with a follow-up prompt — e.g. `llm-start.sh "Check worker progress and review any open PRs"`.

This is by design, not a limitation. One-shot invocations have clean focused context (cheaper tokens, fewer hallucinations from accumulated history), zero idle cost between actions, and are trivially scriptable.

##### Automating the loop

The sandbox ships a built-in event-driven supervisor: `coordinator-watch.sh`. Set `WATCH=1` and `llm-start.sh` spawns it in a sibling tmux window — it watches every worker's `.swarm/tasks/done/` dir and wakes the coordinator each time an outcome JSON appears (debounced by `DEBOUNCE_SECS`).

```bash
WATCH=1 ./llm-start.sh           # coordinator + watcher in one session
```

The watcher's default wake prompt is **top-up mode**: triage finished work, then refill alive workers toward `MAX_WORKERS` from the AVAILABLE backlog. To revert to the conservative "triage-only, don't dispatch" behavior, set `WAKE_PROMPT="..."` to your own text.

Other automation paths if you want them:

- **Time-based:** add a `cron` / `systemd --user` timer running `llm-start.sh "Check status; advance any stalled workers"` every 15min — usually unnecessary if the watcher is on.
- **Conversational:** drop `-p` and run `claude` / `gemini` interactively in Window 1 — possible but burns plan capacity while idle and the context window grows over time. Not recommended for a Max-plan user.

See [`docs/llm-dev-sandbox-overview.md`](./docs/llm-dev-sandbox-overview.md) for the full architecture.

#### Configuring caps and filters

The coordinator and watcher honor a small set of tunables loaded from three sources, **highest precedence wins**:

1. Shell env at invocation time (`MAX_WORKERS=8 ./llm-start.sh ...`)
2. `<project>/.swarm/.env` — durable per-project overrides (gitignored)
3. `<sandbox>/.env.example` — shipped defaults, safe-for-strangers

| Var                          | Default | Purpose                                                                                                          |
|------------------------------|---------|------------------------------------------------------------------------------------------------------------------|
| `MAX_WORKERS`                | `2`     | Concurrent worker tmux windows. Increase consciously — each worker is a Claude Code session using real RAM/quota. |
| `MAX_TMUX_WINDOWS`           | `10`    | Hard cap on total session windows (workers + coordinator + watch + leftover finished worker windows).             |
| `TARGET_AVAILABLE`           | `5`     | Backlog target. Housekeeping creates new issues when AVAILABLE drops below this — NOT when raw open count is low. |
| `OWNER_LABELS`               | empty   | Comma-separated labels treated as "human-owned" (e.g. `sean,radesh`). Skipped unless the label matches `@me`.     |
| `INCLUDE_ASSIGNED_TO_OTHERS` | `0`     | `1` = drop the `@me`-or-unassigned filter; the swarm claims teammates' tickets too.                               |
| `DEBOUNCE_SECS`              | `30`    | Watcher: window during which repeated worker-finish events coalesce into a single coordinator wake.               |
| `POLL_SECS`                  | `2`     | Watcher: polling interval when `inotify-tools` isn't installed.                                                   |

**AVAILABLE** is the coordinator's working definition of "issues a worker can pick up right now":

```
open AND (assignee = @me OR no assignee)
        AND -label:blocked -label:deferred -label:awaiting-review
        AND not human-owner-labeled (per OWNER_LABELS)
        AND not a tracking/meta issue (LLM judgment)
        AND not policy-blocked by .swarm-policy.md (LLM judgment)
        AND no linked open PR
```

The coordinator reports `OPEN=N AVAILABLE=M ALIVE=A/MAX_WORKERS WINDOWS=W/MAX_TMUX_WINDOWS` on every checklist run, so a stalled-but-not-empty backlog ("22 open, 0 available") is visible instead of looking healthy.

##### Per-project setup (durable config)

```bash
mkdir -p /path/to/project/.swarm
cat > /path/to/project/.swarm/.env <<'EOF'
MAX_WORKERS=5
OWNER_LABELS=sean,radesh
EOF
echo '.swarm/' >> /path/to/project/.gitignore   # if not already gitignored
```

For one-shot tuning without editing the file, use the equivalent flags:

```bash
./llm-start.sh --max-workers 5 --owner-labels sean,radesh
```

##### One-shot override modes

When you want the swarm to grab everything (including teammates' tickets) for a single run, just say so in the prompt:

```bash
./llm-start.sh "claim anything open including Radesh's tickets"
```

The coordinator parses free-text intent (`"grab anything"`, `"include others"`, `"regardless of assignee"`) and engages override mode for that run only. For sustained sprints set `INCLUDE_ASSIGNED_TO_OTHERS=1` in `<project>/.swarm/.env`.

#### Live status

`<project>/.swarm/events.log` is an append-only structured log of every observable swarm event — watcher start, worker finish, coordinator wake, sweep run, cap refusal. Tail it for live status:

```bash
tail -F /path/to/project/.swarm/events.log
```

Format: `<utc-iso8601>  <category>  k=v k=v ...`. Greppable. One line per event. Example:

```
2026-05-05T14:23:11Z  watch.start     project=/opt/work/x backend=inotify max_workers=2 max_tmux_windows=10
2026-05-05T14:31:42Z  worker.finish   issue=142 outcome=ok path=.../142.ok.json
2026-05-05T14:31:42Z  coord.wake      issue=142 trigger=20260505-143142-142.ok.json
2026-05-05T14:31:55Z  worker.start    issue=156 task_id=20260505-143155-156 window=iss-156 alive=2/2 total_windows=4/10
2026-05-05T14:32:14Z  cap.refused     issue=178 reason=max_workers alive=2 max=2
```

When `cap.refused` fires repeatedly, close finished `iss-*` windows: `tmux kill-window -t llm-<project>:iss-NN`. The watcher won't auto-close them — your scrollback is preserved for review.

For bulk cleanup, use `kill-finished-workers.sh`. Default: parked-only AND PR-safe (workers tied to an open PR are preserved so you can review the scrollback alongside the PR):

```bash
kill-finished-workers.sh                       # parked + PR-safe (defaults)
kill-finished-workers.sh --dry-run             # preview first
kill-finished-workers.sh --idle-min 5          # require 5+ min of pane inactivity
kill-finished-workers.sh --no-pr-check         # skip the gh round-trip
kill-finished-workers.sh --all                 # include active workers
kill-finished-workers.sh --with-worktree       # also remove worktrees + branches
kill-finished-workers.sh --all --with-worktree # full nuke (prompts for 'yes')
```

`--all --with-worktree` requires confirmation (type `yes`) unless you also pass `--yes` / `-y`.

### 4. Run Manual Sandbox (Single Agent)
If you just want a safe shell for a single agent:

```bash
# Launch Claude Code inside the sandbox for your project
$LLM_SANDBOX_DIR/sandbox.sh /path/to/project claude

# Launch Gemini CLI inside the sandbox
$LLM_SANDBOX_DIR/sandbox.sh /path/to/project gemini
```

---

## ✨ Features at a glance

- **Identity Persistence**: Automatically mounts your host's Claude, GitHub, Git, and SSH configs. No re-authentication needed.
- **Pre-baked Toolchain**: Node.js 22, Java 21, Python 3 (with `uv`), Deno, Docker CLI, and LLM CLIs.
- **GitHub CLI Auth**: Injects your host's `gh` token seamlessly so agents can create PRs out of the box.
- **Git Commit Signing**: Mounts `~/.ssh` correctly so SSH-signed commits pass.
- **Docker-outside-of-Docker (DooD)**: Full support for Testcontainers.
- **Full Linux Userland**: Based on `ubuntu-standard` so agents have `less`, `vim`, `strace`, etc.
- **Auto-top-up Swarm**: Watcher refills workers up to `MAX_WORKERS` as issues finish; hard cap on total tmux windows prevents runaway sessions.
- **Configurable Filters**: Per-project `.swarm/.env` defines who the swarm works for (`@me` + unassigned by default; teammates on opt-in).
- **Structured Event Log**: `tail -F .swarm/events.log` gives live, greppable status of every worker start, finish, and cap refusal.