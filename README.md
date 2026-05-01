# LLM Dev Sandbox

A persistent, local-first sandbox for running LLM agents like **Claude Code**, **Gemini CLI**, and **promptfoo** against your real host services.

## Platform Support

| Platform      | Status          | Notes |
| ------------- | --------------- | ----- |
| Linux (x86_64)| ✅ Tested       | Primary target. Developed on Linux Mint 22 / KDE Neon. |
| macOS         | ⚠️ Untested     | `--network host` has no effect on Docker Desktop for Mac — host services will **not** be reachable via `localhost`. Would need per-port `-p` mappings or `host.docker.internal` instead. SSH agent socket path also differs. |
| Windows (WSL2)| ⚠️ Untested     | Similar networking caveats to macOS. May work with adjustments. |

## Features

- **Identity Persistence**: Mounts your host's Claude, GitHub, Git, and SSH configs — no re-authentication needed.
- **Full Linux Userland**: Based on `buildpack-deps:noble` + `ubuntu-standard` — `less`, `vim`, `man`, `file`, `strace`, and the rest of a proper developer environment are all present.
- **Pre-baked Toolchain**: Node.js 22, Java 21, Python 3 (with `uv`), Deno, Docker CLI, and LLM CLI tools (Claude Code, Gemini CLI, Codex, promptfoo).
- **Full Host Network Access**: Runs with `--network host`, so `localhost` inside the container is your machine's localhost — Postgres, Spring Boot apps, Ollama, etc. are all reachable without any port mapping.
- **GitHub CLI Auth**: Reads `gh auth token` from the host at startup and injects it as `GH_TOKEN` — `gh pr create` and similar commands work out of the box.
- **Git Commit Signing**: Mounts `~/.ssh` at both its host path and `/home/sandbox/.ssh` so SSH-signed commits work (git's `signingkey` uses the absolute host path).
- **Docker-outside-of-Docker (DooD)**: Mounts the host Docker socket so Testcontainers and `docker` CLI work inside the sandbox.
- **Per-project Config**: Drop a `.sandbox-env` file in your project to pre-set credentials and service URLs for agents.

## Setup

### Prerequisites

- Docker installed and running
- `gh` CLI authenticated on the host (for GitHub CLI passthrough)
- SSH key configured for Git signing (if using signed commits)

### Install

1. **Clone the repo**:
   ```bash
   git clone git@github.com:seanoc5/llm-dev-sandbox.git
   cd llm-dev-sandbox
   ```

2. **Build the image** (once, and after any Dockerfile changes):
   ```bash
   docker build -t llm-sandbox:latest .
   ```
   > This takes several minutes on first build — `ubuntu-standard` pulls significant dependencies. Subsequent builds use the layer cache and are much faster.

3. **Make the script executable**:
   ```bash
   chmod +x sandbox.sh
   ```

4. **Verify the setup**:
   ```bash
   ./test-sandbox.sh
   ```

### Run

```bash
# Interactive shell in the current directory
./sandbox.sh

# Interactive shell in a specific project
./sandbox.sh /path/to/project

# Claude Code in a specific project
./sandbox.sh /path/to/project claude

# Gemini CLI
./sandbox.sh /path/to/project gemini

# Pass a prompt directly to Claude
./sandbox.sh /path/to/project claude "explain the architecture of this project"
```

## Persistence

The following host paths are bind-mounted into the container:

| Host path                     | Container path               | Mode | Purpose                         |
| ----------------------------- | ---------------------------- | ---- | ------------------------------- |
| `$PROJECT_DIR`                | `$PROJECT_DIR` (same path)   | `rw` | Project files                   |
| `~/.claude`                   | `/home/sandbox/.claude`      | `rw` | Claude settings & sessions      |
| `~/.claude.json`              | `/home/sandbox/.claude.json` | `rw` | Claude auth token               |
| `~/.ssh`                      | `$HOME/.ssh`                 | `ro` | Git commit signing (abs. path)  |
| `~/.ssh`                      | `/home/sandbox/.ssh`         | `ro` | SSH known_hosts / agent         |
| `~/.gitconfig`                | `/home/sandbox/.gitconfig`   | `ro` | Git identity & signing config   |
| `~/.config/gh`                | `/home/sandbox/.config/gh`   | `ro` | GitHub CLI config               |
| `~/.npm-global`               | `/home/sandbox/.npm-global`  | `rw` | Global npm packages             |
| `~/.bash_history_sandbox`     | `/home/sandbox/.bash_history`| `rw` | Persistent shell history        |

> **Why is `~/.ssh` mounted twice?** Git's `user.signingkey` stores the absolute host path (e.g. `/home/sean/.ssh/id_rsa.pub`). That path must exist inside the container. The second mount at `/home/sandbox/.ssh` covers `ssh-keyscan`, `known_hosts`, and agent forwarding from the sandbox user's home.

## Advanced Usage

### Per-project Environment (`.sandbox-env`)

Create a `.sandbox-env` file in your project directory to pre-set credentials and service URLs. `sandbox.sh` passes it to the container via `--env-file` when present.

```bash
# /opt/work/myproject/.sandbox-env  — gitignore this file
PGHOST=localhost
PGPORT=5432
PGDATABASE=mydb
PGUSER=myuser
PGPASSWORD=mypassword
APP_URL=http://localhost:8080
```

Add `.sandbox-env` to your project's `.gitignore` to avoid committing credentials.

When the sandbox starts, you'll see:
```
Env file:  /path/to/project/.sandbox-env
```

### Extra Mounts

Pass additional mounts via `EXTRA_MOUNTS` (comma-separated). Two formats are supported:

```bash
# Same-path mirror — host path appears at the same path inside the container
EXTRA_MOUNTS="/opt/data/myfiles/:ro" ./sandbox.sh /path/to/project

# Explicit host:container mapping
EXTRA_MOUNTS="/opt/data:/mnt/data:ro" ./sandbox.sh /path/to/project

# Multiple mounts
EXTRA_MOUNTS="/opt/data:ro,/opt/models:/models:ro" ./sandbox.sh /path/to/project
```

### Testcontainers / Docker CLI

The host Docker socket (`/var/run/docker.sock`) is mounted automatically when present. `entrypoint.sh` adds the sandbox user to the docker group at startup (using `DOCKER_GID`) to silence permission errors. `TESTCONTAINERS_HOST_OVERRIDE=localhost` is set automatically so Testcontainers resolves mapped ports correctly with `--network host`.

### Rebuilding the Image

```bash
# After Dockerfile changes
docker build -t llm-sandbox:latest .

# Force a full rebuild (no cache)
docker build --no-cache -t llm-sandbox:latest .

# Check image size
docker images llm-sandbox
```

## Security Considerations

- **Runs as your host UID/GID** — file permissions inside and outside the container match.
- **`--network host`** — the container shares the host network stack. Appropriate for a local dev tool; not suitable for untrusted workloads.
- **Docker socket** — mounting `/var/run/docker.sock` gives the container full Docker daemon access. This is inherent to DooD and unavoidable if you need Testcontainers.
- **SSH keys** — mounted read-only. The agent can use them but cannot modify or exfiltrate them any more easily than any other process running as your user.
- **`--dangerously-skip-permissions` / `--yolo`** — Claude Code and Gemini CLI run in auto-approve mode inside the sandbox. Review what the agent is doing; the sandbox does not prevent destructive file operations on mounted directories.

## Troubleshooting

### `groups: cannot find name for group ID NNN`
Harmless warning on first start — `entrypoint.sh` suppresses it by registering the docker group. If it persists, rebuild the image.

### `gh: HTTP 401`
The host `gh` token was not forwarded. Check that `gh auth status` works on the host. The token is read at sandbox startup via `gh auth token`.

### `git commit` fails with signing error
Verify `~/.ssh/id_rsa.pub` (or whatever `user.signingkey` points to) exists on the host. The path must be the literal value in `.gitconfig` — the container mounts `~/.ssh` at that exact path.

### Host service not reachable from sandbox
On Linux, `--network host` means `localhost` inside the container is the host. Confirm the service is actually listening:
```bash
ss -tlnp | grep <port>
```
On macOS/Windows, `--network host` does not work with Docker Desktop — see [Platform Support](#platform-support).

### `psql` connects but `pg_isready -h localhost` fails
`pg_isready` without `-h` uses the Unix socket by default. Specify `-h localhost` to force TCP, which is what `--network host` gives you.
