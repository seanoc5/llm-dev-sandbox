#!/usr/bin/env bash
#
# sandbox.sh — Generalized LLM Sandbox
set -euo pipefail

# --- Configuration ---
# Default to current directory if no path is provided
PROJECT_DIR="$(realpath "${1:-$PWD}")"
if [ $# -gt 0 ]; then shift; fi

# Determine the agent (claude, gemini, or bash)
AGENT="bash"
if [[ $# -gt 0 ]]; then
    if [[ "$1" == "claude" || "$1" == "gemini" ]]; then
        AGENT="$1"
        shift
    fi
fi

IMAGE="llm-sandbox:latest"

# Build if image doesn't exist
if ! docker image inspect "$IMAGE" &>/dev/null; then
    echo "Building sandbox image..."
    # Assumes Dockerfile is in the same directory as this script
    docker build -t "$IMAGE" "$(dirname "$0")"
fi

# Ensure host config dirs exist for persistence
mkdir -p "$HOME/.claude" "$HOME/.npm-global"
if [ ! -f "$HOME/.bash_history_sandbox" ]; then
    touch "$HOME/.bash_history_sandbox"
fi
touch "$HOME/.claude.json"

# --- Mount strategy ---
# Maps host configs into the container's standard home (/home/sandbox)
MOUNTS=(
    -v "$PROJECT_DIR:/workspace:rw"
    -v "$HOME/.claude:/home/sandbox/.claude:rw"
    -v "$HOME/.claude.json:/home/sandbox/.claude.json:rw"
    -v "$HOME/.gitconfig:/home/sandbox/.gitconfig:ro"
    -v "$HOME/.config/gh:/home/sandbox/.config/gh:ro"
    -v "$HOME/.bash_history_sandbox:/home/sandbox/.bash_history:rw"
    -v "$HOME/.npm-global:/home/sandbox/.npm-global:rw"
    -v "$HOME/.npm:/home/sandbox/.npm:rw"
)

# Allow for additional mounts via environment variable
if [ -n "${EXTRA_MOUNTS:-}" ]; then
    IFS=',' read -ra ADDR <<< "$EXTRA_MOUNTS"
    for mount in "${ADDR[@]}"; do MOUNTS+=("-v" "$mount"); done
fi

# SSH Agent Forwarding
SSH_OPTS=()
if [ -n "${SSH_AUTH_SOCK:-}" ]; then
    SSH_OPTS=(-v "$SSH_AUTH_SOCK:/tmp/ssh-agent.sock" -e SSH_AUTH_SOCK=/tmp/ssh-agent.sock)
fi

# TTY handling
INTERACTIVE_FLAGS=()
if [ -t 0 ]; then
    INTERACTIVE_FLAGS=("-it")
fi

# Construct command as an array
CMD_ARRAY=()
if [[ $# -eq 0 ]]; then
    case "$AGENT" in
        claude) CMD_ARRAY=("claude" "--dangerously-skip-permissions") ;;
        gemini) CMD_ARRAY=("gemini" "--yolo") ;;
        *)      CMD_ARRAY=("bash" "-i") ;;
    esac
else
    case "$AGENT" in
        claude) CMD_ARRAY=("claude" "$@" "--dangerously-skip-permissions") ;;
        gemini) CMD_ARRAY=("gemini" "$@" "--yolo") ;;
        *)      CMD_ARRAY=("bash" "-c" "$*") ;;
    esac
fi

echo "--- LLM Sandbox Session ---"
echo "Project:  $PROJECT_DIR"
echo "Agent:    $AGENT"
echo "---------------------------"

docker run "${INTERACTIVE_FLAGS[@]}" --rm --init \
    --hostname "sandbox" \
    --user "$(id -u):$(id -g)" \
    --workdir "/workspace" \
    --add-host host.docker.internal:host-gateway \
    "${MOUNTS[@]}" \
    "${SSH_OPTS[@]}" \
    -e "TERM=$TERM" \
    -e "COLORTERM=${COLORTERM:-}" \
    "$IMAGE" \
    "${CMD_ARRAY[@]}"
