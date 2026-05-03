# LLM Dev Sandbox

A persistent, local-first **convenience-isolation layer** for running LLM agents like **Claude Code**, **Gemini CLI**, and **promptfoo** against your real host services.

Running autonomous LLM agents directly on your host is risky — agents can hallucinate destructive shell commands. This wrapper reduces blast radius for honest mistakes (typos, hallucinated `rm -rf`, wrong cwd) by running the agent inside a Docker container that only has the project dir mounted rw plus the auth state it needs.

> ⚠️ **This is NOT a security boundary against a hostile / compromised agent.**
> The container runs with `--network host`, mounts `/var/run/docker.sock` for Docker-out-of-Docker, mounts `~/.claude` rw and `~/.ssh` ro, and the agents run with `--dangerously-skip-permissions` / `--yolo`. A sufficiently-capable agent inside the container can spawn sibling containers with `-v /:/host`, exfiltrate your gh token, push to your repos, etc. Treat the agents as **trusted-but-fallible**, not as adversaries. See [`docs/security.md`](./docs/security.md) for blast-radius details.

By running locally with `--network host`, the agent can interact with your entire local development environment (e.g., local Postgres, Spring Boot) exactly as you do, without complex tunneling.

---

## 📚 Documentation Index

For deep-dives into specific topics, please refer to the reference documentation:
- 🏗️ [**Architecture & Orchestration**](./docs/architecture.md) - Learn how the Coordinator -> Worker pattern uses Git worktrees to run multiple agents in parallel.
- ⚙️ [**Advanced Usage**](./docs/advanced-usage.md) - Manual worktree setup, Testcontainers, `.sandbox-env`, and custom bind mounts.
- 🛡️ [**Security Considerations**](./docs/security.md) - Understand the blast radius and the risks of `--yolo` / Docker-out-of-Docker.
- 🚑 [**Troubleshooting**](./docs/troubleshooting.md) - Fix common SSH, `gh` auth, and networking errors.

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

# One-time host-side setup (idempotent; re-run after gemini-cli upgrades)
./setup.sh
```

`setup.sh` symlinks the system `rg` into the path `@google/gemini-cli` looks for (the npm package omits its bundled binary). Without it gemini logs `Ripgrep is not available. Falling back to GrepTool.` on every run and uses a slower built-in matcher.

### 3. Run Autonomous Swarm (Recommended)
Let the coordinator triage your backlog and provision worker agents.

```bash
# Navigate to any project you want to work on
cd /opt/work/myproject

# Bootstrap the coordinator (gemini default; COORDINATOR_CMD=claude to use Claude Max)
/opt/work/sysadmin/llm-dev-sandbox/llm-start.sh "Optional initial prompt; default: run startup checklist"
```
This creates a dedicated `tmux` session, runs the coordinator in Window 1 with the prompt you supplied (default: survey GitHub issues + provision workers), and spawns isolated Claude worker agents in dockerized git worktrees, one per dispatched issue.

**Common env-var combinations:**

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

If you want the coordinator to wake on a schedule or on events, wrap the one-shot invocation:

- **Time-based:** add a `cron` / `systemd --user` timer that runs `llm-start.sh "Check status; advance any stalled workers"` every 15min.
- **Event-driven:** use `inotifywait` (or a webhook handler) on `tasks/done/` markers — wakes the coordinator the moment a worker finishes. (Requires the queued-worker protocol from `todo/TODO.md`.)
- **Conversational:** drop `-p` and run `claude`/`gemini` interactively in Window 1 — possible but burns plan capacity while idle and the context window grows over time. Not recommended for a Max-plan user.

See [`docs/llm-dev-sandbox-overview.md`](./docs/llm-dev-sandbox-overview.md) for the full architecture.

### 4. Run Manual Sandbox (Single Agent)
If you just want a safe shell for a single agent:

```bash
# Launch Claude Code inside the sandbox for your project
/opt/work/sysadmin/llm-dev-sandbox/sandbox.sh /path/to/project claude

# Launch Gemini CLI inside the sandbox
/opt/work/sysadmin/llm-dev-sandbox/sandbox.sh /path/to/project gemini
```

---

## ✨ Features at a glance

- **Identity Persistence**: Automatically mounts your host's Claude, GitHub, Git, and SSH configs. No re-authentication needed.
- **Pre-baked Toolchain**: Node.js 22, Java 21, Python 3 (with `uv`), Deno, Docker CLI, and LLM CLIs.
- **GitHub CLI Auth**: Injects your host's `gh` token seamlessly so agents can create PRs out of the box.
- **Git Commit Signing**: Mounts `~/.ssh` correctly so SSH-signed commits pass.
- **Docker-outside-of-Docker (DooD)**: Full support for Testcontainers.
- **Full Linux Userland**: Based on `ubuntu-standard` so agents have `less`, `vim`, `strace`, etc.