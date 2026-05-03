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

        # Echo the task brief so anyone attached to this tmux window can see
        # what the worker is actually working on (otherwise the user just
        # sees a blank "Executing task..." line until the agent prints its
        # first tool call). Truncate after a sane line count to avoid
        # spamming the pane on huge prompts; the full text is always still
        # available in .agent-task-last.md.
        echo "--- Task brief (first 40 lines of .agent-task-last.md) ---"
        printf '%s\n' "$TASK" | head -40
        TASK_LINES=$(printf '%s\n' "$TASK" | wc -l)
        if [ "$TASK_LINES" -gt 40 ]; then
            echo "... [truncated; $TASK_LINES total lines — see .agent-task-last.md for full] ..."
        fi
        echo "----------------------------------------------------------"

        echo "[$(date +%T)] Executing task..."
        
        # Run the agent with the task in headless/print mode so it executes
        # non-interactively (no trust-folder dialog, no chat loop) and exits
        # when done. The listener loop then waits for the next task.
        if [[ "$AGENT" == "claude" ]]; then
            claude -p "$TASK" --dangerously-skip-permissions
        elif [[ "$AGENT" == "gemini" ]]; then
            gemini -p "$TASK" --yolo --skip-trust
        else
            bash -c "$TASK"
        fi
        
        echo "------------------------------"
        echo "[$(date +%T)] Task complete. Waiting for next..."
    fi
    sleep 2
done
