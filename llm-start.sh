#!/usr/bin/env bash
#
# llm-start.sh - Bootstrap the multi-agent tmux session
#
# This script creates a dedicated tmux session for the current project,
# spawns the Gemini Coordinator agent in the first window, and issues
# its initial startup command.
set -euo pipefail

# Configuration
SESSION_NAME="llm-$(basename "$PWD")"
PROMPT_FILE="/opt/work/sysadmin/llm-dev-sandbox/COORDINATOR_SYSTEM_PROMPT.md"

# Check if already inside tmux
IN_TMUX=false
if [ -n "${TMUX:-}" ]; then
    IN_TMUX=true
fi

if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "Creating new multi-agent session: $SESSION_NAME"
    
    # Create a detached session, name the first window "coordinator"
    tmux new-session -d -s "$SESSION_NAME" -n "coordinator"
    
    # Launch Gemini CLI with the system prompt
    tmux send-keys -t "$SESSION_NAME:coordinator" "gemini --system-prompt '$PROMPT_FILE'" C-m
    
    # Wait a brief moment to ensure Gemini has initialized and is ready for input
    sleep 2
    
    # Feed the initial starting directive
    tmux send-keys -t "$SESSION_NAME:coordinator" "Execute the Initial Startup Checklist." C-m
else
    echo "Session $SESSION_NAME already exists."
fi

# Attach or switch to the session
echo "Connecting to Coordinator..."
if $IN_TMUX; then
    # If we are already in tmux, switch the client to the new session
    tmux switch-client -t "$SESSION_NAME"
else
    # Otherwise, attach normally
    tmux attach -t "$SESSION_NAME"
fi