#!/usr/bin/env bash
#
# worker-listener.sh — Asynchronous "Inbox" watcher for worker agents.
#
# This script runs inside a worktree sandbox. It watches for a .agent-task.md
# file, executes the task using the local agent, and then waits for the next.

AGENT="${1:-claude}"
TASK_FILE=".agent-task.md"

echo "--- Worker Listener Active ---"
echo "Agent:  $AGENT"
echo "Watching for: $TASK_FILE"
echo "------------------------------"

while true; do
    if [ -f "$TASK_FILE" ]; then
        echo "[$(date +%T)] Task received!"
        
        # Read the task
        TASK=$(cat "$TASK_FILE")
        
        # Archive/Rename the task file so we don't run it twice
        mv "$TASK_FILE" ".agent-task-last.md"
        
        echo "[$(date +%T)] Executing task..."
        
        # Run the agent with the task
        # We use 'eval' or direct call depending on how the agent handles input
        if [[ "$AGENT" == "claude" ]]; then
            claude "$TASK"
        elif [[ "$AGENT" == "gemini" ]]; then
            gemini "$TASK"
        else
            bash -c "$TASK"
        fi
        
        echo "------------------------------"
        echo "[$(date +%T)] Task complete. Waiting for next..."
    fi
    sleep 2
done
