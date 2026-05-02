# Advanced Usage & Configuration

This document covers advanced workflows, custom mounts, and manual Git worktree setups.

## Git Worktrees

`sandbox.sh` automatically detects git worktrees. When the project directory is a worktree (its `.git` is a file pointing to the main repo), the script mounts the main repo's `.git/` directory into the container so all git operations work normally.

### Manual Multi-worktree tmux setup

While `llm-start.sh` handles orchestration autonomously, you can manually use `sandbox-worktrees.sh` to list worktrees and optionally create tmux windows and/or launch sandboxes:

```bash
# List all worktrees and their branches
./sandbox-worktrees.sh /opt/work/myproject

# Launch Claude sandbox in the current shell for this worktree
./sandbox-worktrees.sh -a claude

# Create tmux windows starting at 7 — one per worktree
./sandbox-worktrees.sh -t /opt/work/myproject

# Create tmux windows AND launch Claude in each
./sandbox-worktrees.sh -t -a claude /opt/work/myproject

# Start at window 3 (implies -t)
./sandbox-worktrees.sh -s 3 -a gemini /opt/work/myproject
```

The `-a` flag behaves differently depending on whether `-t` is present:
- **`-a` alone:** launches the sandbox in the current shell via `exec` (replaces the shell process).
- **`-t -a`:** creates tmux windows and launches a sandbox in each.

This pairs well with projects that use docker compose with per-worktree port offsets (via `.env` files), letting you run fully isolated stacks side by side. A typical setup:

```
Window 7:  fand-api       (main worktree, master)     → ports 35432, 18081, 18082
Window 8:  fand-api-wt1   (feature/new-batch-job)     → ports 35433, 18084, 18083
Window 9:  fand-api-wt2   (fix/dashboard-bug)         → ports 35434, 18086, 18085
Window 10: fand-api-wt3   (spike/experiment)           → ports 35435, 18088, 18087
```

### Creating worktrees manually

```bash
# From the main repo — create worktrees alongside it
cd /opt/work/myproject
git worktree add ../myproject-wt1 master
git worktree add ../myproject-wt2 --detach HEAD

# List all worktrees
git worktree list

# Clean up when done
git worktree remove ../myproject-wt2
```

## Custom Configuration

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

## Docker Integrations

### Testcontainers / Docker CLI

The host Docker socket (`/var/run/docker.sock`) is mounted automatically when present. `entrypoint.sh` adds the sandbox user to the docker group at startup (using `DOCKER_GID`) to silence permission errors. `TESTCONTAINERS_HOST_OVERRIDE=localhost` is set automatically so Testcontainers resolves mapped ports correctly with `--network host`.

### Rebuilding the Image

```bash
# After Dockerfile changes
docker build -t llm-sandbox:latest .

# Force a full rebuild (no cache)
docker build --no-cache -t llm-sandbox:latest .
```