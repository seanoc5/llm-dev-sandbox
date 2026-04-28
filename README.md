# LLM Dev Sandbox

A secure, persistent, and local-first sandbox for running LLM agents like **Claude Code**, **Gemini CLI**, and **promptfoo**.

## Features

- **Identity Persistence**: Automatically mounts your host's Claude, GitHub, and Git configurations so you don't have to re-authenticate or lose your themes.
- **Pre-baked Toolchain**: Includes Node.js 22, Java 21, Python 3 (with `uv`), Deno, and essential LLM CLI tools.
- **Local File Access**: Uses bind mounts for instantaneous sync between your host and the sandbox.
- **Network Isolation**: Accessible host services (like Ollama or Postgres) via `host.docker.internal`.

## Setup

1.  **Clone the repo**:
    ```bash
    git clone <your-repo-url>
    cd llm-sandbox-dist
    ```

2.  **Make the script executable**:
    ```bash
    chmod +x sandbox.sh
    ```

3.  **Run the sandbox**:
    ```bash
    # Launch an interactive shell in the current directory
    ./sandbox.sh

    # Launch Claude Code directly in a specific project
    ./sandbox.sh /path/to/project claude

    # Launch Gemini CLI
    ./sandbox.sh /path/to/project gemini
    ```

## Persistence

The following host directories are mapped into the container for persistence:
- `~/.claude` & `~/.claude.json` (Claude settings and sessions)
- `~/.gitconfig` & `~/.config/gh` (Git and GitHub CLI)
- `~/.npm-global` (Globally installed NPM packages)
- `~/.bash_history_sandbox` (Command history)

## Advanced Usage

### Extra Mounts
You can provide additional read-only or read-write mounts via the `EXTRA_MOUNTS` environment variable:

```bash
EXTRA_MOUNTS="/path/to/data:/mnt/data:ro" ./sandbox.sh .
```

## Security

- The sandbox runs as your host user (UID/GID) to ensure file permissions match.
- SSH agent forwarding is supported but optional.
- **Caution**: The sandbox has read-write access to the mounted project directory.

