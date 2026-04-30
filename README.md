# LLM Dev Sandbox

A persistent, local-first sandbox for running LLM agents like **Claude Code**, **Gemini CLI**, and **promptfoo** against your real host services.

## Features

- **Identity Persistence**: Mounts your host's Claude, GitHub, Git, and SSH configs — no re-authentication needed.
- **Pre-baked Toolchain**: Node.js 22, Java 21, Python 3 (with `uv`), Deno, Docker CLI, and essential LLM CLI tools.
- **Full Host Network Access**: Runs with `--network host`, so `localhost` inside the container is your machine's localhost — Postgres, Spring Boot apps, Ollama, etc. are all reachable without any port mapping.
- **GitHub CLI Auth**: Reads `gh auth token` from the host at startup and injects it as `GH_TOKEN` — `gh pr create` and similar commands work out of the box.
- **Docker-outside-of-Docker (DooD)**: Mounts the host Docker socket so Testcontainers and `docker` CLI work inside the sandbox.
- **Per-project Config**: Drop a `.sandbox-env` file in your project to pre-set credentials and service URLs for agents.

## Setup

1. **Clone the repo**:
   ```bash
   git clone <your-repo-url>
   cd llm-sandbox-dist
   ```

2. **Build the image** (once, and after any Dockerfile changes):
   ```bash
   docker build -t llm-sandbox:latest .
   ```

3. **Make the script executable**:
   ```bash
   chmod +x sandbox.sh
   ```

4. **Run the sandbox**:
   ```bash
   # Interactive shell in the current directory
   ./sandbox.sh

   # Claude Code in a specific project
   ./sandbox.sh /path/to/project claude

   # Gemini CLI
   ./sandbox.sh /path/to/project gemini
   ```

## Persistence

The following host paths are bind-mounted into the container:

| Host path                    | Container path              | Purpose                        |
| ---------------------------- | --------------------------- | ------------------------------ |
| `~/.claude`                  | `/home/sandbox/.claude`     | Claude settings & sessions     |
| `~/.claude.json`             | `/home/sandbox/.claude.json`| Claude auth                    |
| `~/.ssh`                     | `$HOME/.ssh`                | Git commit signing (abs. path) |
| `~/.ssh`                     | `/home/sandbox/.ssh`        | SSH known_hosts / agent        |
| `~/.gitconfig`               | `/home/sandbox/.gitconfig`  | Git identity & signing config  |
| `~/.config/gh`               | `/home/sandbox/.config/gh`  | GitHub CLI config              |
| `~/.npm-global`              | `/home/sandbox/.npm-global` | Global npm packages            |
| `~/.bash_history_sandbox`    | `/home/sandbox/.bash_history`| Shell history                 |
| `$PROJECT_DIR`               | `$PROJECT_DIR` (same path)  | Project files (read-write)     |

## Advanced Usage

### Per-project Environment (`.sandbox-env`)

Create a `.sandbox-env` file in your project directory to pre-set credentials and service URLs. `sandbox.sh` passes it to the container via `--env-file` when present.

```bash
# /opt/work/myproject/.sandbox-env  — gitignore this file
PGHOST=localhost
PGPORT=35432
PGDATABASE=mydb
PGUSER=myuser
PGPASSWORD=mypassword
APP_URL=http://localhost:18081
```

Add `.sandbox-env` to your project's `.gitignore` to avoid committing credentials.

### Extra Mounts

Pass additional mounts via `EXTRA_MOUNTS` (comma-separated). Two formats are supported:

```bash
# Same-path mirror (host path appears at the same path inside the container)
EXTRA_MOUNTS="/opt/data/onedrive/OconEco/claude/:ro" ./sandbox.sh /path/to/project

# Explicit host:container mapping
EXTRA_MOUNTS="/opt/data:/mnt/data:ro" ./sandbox.sh /path/to/project

# Multiple mounts
EXTRA_MOUNTS="/opt/data:ro,/opt/models:/models:ro" ./sandbox.sh /path/to/project
```

### Testcontainers / Docker CLI

The host Docker socket is mounted automatically when present (`/var/run/docker.sock`). The container is added to the docker group at startup via `entrypoint.sh`. Integration tests using Testcontainers work without any extra configuration — `TESTCONTAINERS_HOST_OVERRIDE=localhost` is set automatically to match the `--network host` setup.

## Security

- Runs as your host UID/GID — file permissions match the host.
- SSH agent forwarding is supported when `SSH_AUTH_SOCK` is set.
- `--network host` means the container shares the host network stack — appropriate for a local dev tool, not for untrusted workloads.
- The Docker socket mount gives the container full Docker daemon access (inherent to DooD).
- **Caution**: The sandbox has read-write access to the mounted project directory.
