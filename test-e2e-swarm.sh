#!/usr/bin/env bash
#
# test-e2e-swarm.sh — End-to-End Local Orchestration Test
#
# This script creates a temporary local git repository, launches the
# Coordinator, and issues a test prompt to verify that it can successfully
# spawn worker nodes in isolated worktrees to perform local tasks.
set -euo pipefail

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }

TEST_DIR="/tmp/swarm-e2e-$(date +%s)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

echo "=== Swarm E2E Test ==="
yellow "Cleaning up previous sessions..."
tmux kill-session -t "llm-main-repo" 2>/dev/null || true

yellow "Creating temporary workspace at: $TEST_DIR"
mkdir -p "$TEST_DIR/main-repo"
# Copy the .env file so the agent can authenticate
cp /opt/work/sysadmin/llm-dev-sandbox/.env "$TEST_DIR/main-repo/.env" 2>/dev/null || cp /opt/work/sysadmin/.env "$TEST_DIR/main-repo/.env" 2>/dev/null || yellow "Warning: No .env found to copy."

cd "$TEST_DIR/main-repo"

# Initialize a local dummy repo
git init -b main >/dev/null
echo "# Dummy Repo" > README.md
git add README.md
git commit -m "Initial commit" >/dev/null

# Define the highly constrained test prompt
TEST_PROMPT=$(cat <<EOF
IGNORE YOUR STANDARD STARTUP CHECKLIST. DO NOT INTERACT WITH GITHUB.
This is a local integration test. Please execute the following steps exactly:
1. Create a git worktree at '../wt-alpha' on branch 'feature/alpha'.
2. Create a git worktree at '../wt-beta' on branch 'feature/beta'.
3. Spawn a worker listener in '../wt-alpha' using your standard tmux new-window command.
4. Spawn a worker listener in '../wt-beta' using your standard tmux new-window command.
5. Drop an .agent-task.md in '../wt-alpha' instructing the worker to create a file named 'alpha-success.txt' containing the word 'ALPHA'.
6. Drop an .agent-task.md in '../wt-beta' instructing the worker to create a file named 'beta-success.txt' containing the word 'BETA'.
EOF
)

yellow "Launching Coordinator with E2E test prompt..."
# Launch using our refactored llm-start.sh, passing the custom prompt
export NON_INTERACTIVE=1
"$SCRIPT_DIR/llm-start.sh" "$TEST_PROMPT"

echo ""
yellow "Waiting up to 90 seconds for workers to complete their tasks..."
echo "You can open another terminal and run 'tmux a' to watch them work!"

# Poll for success
MAX_WAITS=30
LAST_SCREEN_DUMP=""
STUCK_COUNT=0
for ((i=1; i<=MAX_WAITS; i++)); do
    sleep 3
    
    # Check if the session is still alive
    if ! tmux has-session -t "llm-main-repo" 2>/dev/null; then
        echo ""
        red "✗ Session crashed! The coordinator tmux session is no longer running."
        exit 1
    fi
    
    # Capture the current screen of the coordinator window
    SCREEN_DUMP=$(tmux capture-pane -p -t "llm-main-repo:coordinator")
    
    # Stuck detection: the coordinator typically exits within ~20s of launching
    # (fast in -p mode), then the pane sits idle while workers spin up their
    # docker containers and run claude (~5-20s each). So "no change in coordinator
    # pane" is a normal mid-test state, not a hang. Only treat the run as stuck
    # if the pane is unchanged for the bulk of the budget (~60s = 20 loops).
    if [ "$SCREEN_DUMP" == "$LAST_SCREEN_DUMP" ]; then
        # NOTE: `((STUCK_COUNT++))` returns the OLD value as its exit code,
        # so when STUCK_COUNT is 0 the arithmetic eval exits 1 and `set -e`
        # silently kills the script. Use arithmetic assignment to avoid this.
        STUCK_COUNT=$((STUCK_COUNT + 1))
    else
        STUCK_COUNT=0
    fi
    LAST_SCREEN_DUMP="$SCREEN_DUMP"

    if [ $STUCK_COUNT -ge 20 ]; then
        echo ""
        red "✗ Process appears stuck (no output change for 60s). Killing session."
        tmux kill-session -t "llm-main-repo" 2>/dev/null || true
        exit 1
    fi

    # Check for obvious errors in the pane, but only show the matching line to save tokens.
    # `|| true` guards against pipefail killing the script when grep finds no
    # matches (which is the *expected* case on a healthy run).
    ERROR_LINE=$(echo "$SCREEN_DUMP" | grep -iE "error|exception|not found|command not found|try again|missing API key" | tail -n 1 || true)
    if [ -n "$ERROR_LINE" ]; then
         echo ""
         red "✗ Error detected in Coordinator window!"
         red "> $ERROR_LINE"
         yellow "Full dump saved to /tmp/swarm-error.log"
         echo "$SCREEN_DUMP" > /tmp/swarm-error.log
         tmux kill-session -t "llm-main-repo" 2>/dev/null || true
         exit 1
    fi

    printf "."
    
    # Check if both workers successfully created their target files
    if [ -f "$TEST_DIR/wt-alpha/alpha-success.txt" ] && [ -f "$TEST_DIR/wt-beta/beta-success.txt" ]; then
        echo ""
        green "✓ Success! Both workers received tasks and executed them."
        
        # Cleanup
        if [ "${KEEP_ALIVE:-0}" != "1" ]; then
            tmux kill-session -t "llm-main-repo" 2>/dev/null || true
            rm -rf "$TEST_DIR"
        else
            yellow "KEEP_ALIVE=1 is set. Leaving tmux session 'llm-main-repo' running for review."
        fi
        exit 0
    fi
done

echo ""
red "✗ Timeout. The workers did not complete the tasks in time."
red "Please attach to the tmux session (tmux a) to see where it got stuck."
if [ "${KEEP_ALIVE:-0}" != "1" ]; then
    tmux kill-session -t "llm-main-repo" 2>/dev/null || true
fi
exit 1
