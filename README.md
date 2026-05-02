# LLM Dev Sandbox

A persistent, local-first sandbox for running LLM agents like **Claude Code**, **Gemini CLI**, and **promptfoo** against your real host services.

Running autonomous LLM agents directly on your host machine is inherently risky. Agents can hallucinate destructive shell commands or execute rogue code. This sandbox provides a containment layer that **protects your host system** while granting the agent access to the specific project files and network services it needs to be useful. 

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
```

### 3. Run Autonomous Swarm (Recommended)
The premier way to use this sandbox is to let the AI manage the infrastructure.

```bash
# Navigate to any project you want to work on
cd /opt/work/myproject

# Bootstrap the AI Orchestrator
/opt/work/sysadmin/llm-dev-sandbox/llm-start.sh
```
This creates a dedicated `tmux` session, opens Gemini in Window 1, and instructs it to autonomously survey your GitHub issues, spin up isolated Claude worker agents in the background, and manage their PR output.

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