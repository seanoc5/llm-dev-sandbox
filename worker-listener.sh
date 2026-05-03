#!/usr/bin/env bash
#
# worker-listener.sh — Asynchronous "Inbox" watcher for worker agents.
#
# This script runs inside a worktree sandbox. It watches for a .agent-task.md
# file, executes the task using the local agent, and then waits for the next.
#
# Mode (controlled by WORKER_HEADLESS env var):
#   default            — interactive. Agent runs the seeded prompt, then stays
#                        alive in REPL so an attached user can answer questions
#                        the agent asks. Exit with /quit (claude) or Ctrl-D.
#                        First run per worktree: claude prompts "Trust this
#                        folder? Y/n" — answer Y to proceed.
#   WORKER_HEADLESS=1  — agent runs with -p (claude) / -p (gemini), prints,
#                        and exits. Skips the trust dialog. Used by e2e tests
#                        and any automation where no human is attached.

AGENT="${1:-claude}"
MODEL="${WORKER_MODEL:-}"
TASK_FILE=".agent-task.md"
HEADLESS="${WORKER_HEADLESS:-0}"

# Build per-agent model flag from WORKER_MODEL (no-op when unset → use the
# agent CLI's own default). claude uses --model, gemini uses -m.
MODEL_OPTS=()
if [ -n "$MODEL" ]; then
    case "$AGENT" in
        claude) MODEL_OPTS=(--model "$MODEL") ;;
        gemini) MODEL_OPTS=(-m "$MODEL") ;;
    esac
fi

echo "--- Worker Listener Active ---"
echo "Agent:  $AGENT${MODEL:+ (model: $MODEL)}"
echo "Mode:   $([ "$HEADLESS" = "1" ] && echo headless || echo interactive)"
echo "Watching for: $TASK_FILE"
[ "$HEADLESS" = "1" ] || cat <<'NOTE'

  Interactive mode: agent will run the seeded prompt and then drop to
  its REPL. Attach with `tmux a -t <session>` and switch to this window
  to interact. On first run claude will ask "Trust this folder?" — say Y.
  When done, /quit (claude) or Ctrl-D (gemini) to release the listener
  for the next task. Set WORKER_HEADLESS=1 to disable.

NOTE
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

        # Default: interactive — agent runs the seeded prompt, prints tool
        # calls + final answer, then drops to its REPL so an attached user
        # can answer follow-up questions. The listener loop is blocked here
        # until the agent exits (/quit or Ctrl-D).
        #
        # WORKER_HEADLESS=1: revert to print-and-exit semantics. Used by the
        # e2e test path (which has no human attached) and any automation.
        # `-p` also skips claude's "Trust this folder?" dialog by design.
        if [[ "$AGENT" == "claude" ]]; then
            if [ "$HEADLESS" = "1" ]; then
                claude "${MODEL_OPTS[@]}" -p "$TASK" --dangerously-skip-permissions
            else
                claude "${MODEL_OPTS[@]}" "$TASK" --dangerously-skip-permissions
            fi
        elif [[ "$AGENT" == "gemini" ]]; then
            if [ "$HEADLESS" = "1" ]; then
                gemini "${MODEL_OPTS[@]}" -p "$TASK" --yolo --skip-trust
            else
                gemini "${MODEL_OPTS[@]}" -i "$TASK" --yolo --skip-trust
            fi
        else
            bash -c "$TASK"
        fi
        
        echo "------------------------------"
        echo "[$(date +%T)] Task complete. Waiting for next..."
    fi
    sleep 2
done
