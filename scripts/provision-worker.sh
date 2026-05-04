#!/usr/bin/env bash
#
# provision-worker.sh — coordinator helper to provision a worker for an issue.
#
# Usage:   provision-worker.sh <issue-number> [project-dir]
# Example: provision-worker.sh 142
#          provision-worker.sh 142 /opt/work/oconeco/fand-api
#
# Wraps the multi-step "create worktree, init queue, build brief with
# .swarm-policy.md guardrails embedded, atomic write, spawn worker tmux
# window" workflow into a single command call. The coordinator (gemini or
# claude) invokes this once per dispatch — no $(...) substitution at the
# coordinator's tool layer, so gemini's run_shell_command guardrails are
# satisfied.
#
# Re-running for the same issue is idempotent: a pre-existing worktree
# is reused (no re-create), and the new task is queued via a fresh task
# id so the listener processes it as a follow-up.
set -euo pipefail

ISSUE="${1:?usage: provision-worker.sh <issue-number> [project-dir]}"
PROJECT_DIR="${2:-$PWD}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
WT="$(dirname "$PROJECT_DIR")/wt-issue-$ISSUE"
BRANCH="fix/issue-$ISSUE"
SESSION_NAME="llm-$(basename "$PROJECT_DIR")"
SANDBOX_SH="${SANDBOX_SH:-/opt/work/sysadmin/llm-dev-sandbox/sandbox.sh}"

echo "=== provision-worker.sh ==="
echo "issue:      #$ISSUE"
echo "project:    $PROJECT_DIR"
echo "worktree:   $WT"
echo "branch:     $BRANCH"
echo "tmux:       $SESSION_NAME / iss-$ISSUE"
echo

cd "$PROJECT_DIR"

# 1. Worktree (idempotent)
if [ -d "$WT" ]; then
    echo "[1/4] worktree already exists — reusing"
else
    git worktree add "$WT" -b "$BRANCH"
    echo "[1/4] worktree created"
fi

# 2. Queue dirs (idempotent — listener also creates them on startup)
mkdir -p "$WT/.swarm/tasks/inbox" "$WT/.swarm/tasks/processing" "$WT/.swarm/tasks/done"
echo "[2/4] queue dirs ready"

# 3. Build task brief atomically (mktemp+mv inside same FS = atomic rename)
TASK_ID="$(date +%Y%m%d-%H%M%S)-$ISSUE"
TMP="$(mktemp -p "$WT/.swarm/tasks/inbox" .tmp.XXXXXX.md)"
{
    if [ -f .swarm-policy.md ]; then
        echo "## Project Guardrails (MUST OBEY)"
        echo
        cat .swarm-policy.md
        echo
        echo "---"
        echo
    fi
    echo "## Task"
    echo
    echo "Fix issue #$ISSUE. Details follow."
    echo
    gh issue view "$ISSUE"
} > "$TMP"
mv "$TMP" "$WT/.swarm/tasks/inbox/$TASK_ID.md"
echo "[3/4] brief queued: $WT/.swarm/tasks/inbox/$TASK_ID.md"

# 4. Spawn worker tmux window (background — does NOT steal focus from coordinator)
# If the session doesn't exist, fail clearly — the coordinator should be
# running inside the session, so it should always exist by the time we
# reach this script.
if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "ERROR: tmux session '$SESSION_NAME' does not exist." >&2
    echo "  (Are you running this from inside the coordinator's session?)" >&2
    exit 2
fi

# Skip if a window for this issue already exists
if tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep -qx "iss-$ISSUE"; then
    echo "[4/4] tmux window iss-$ISSUE already exists — listener will pick up the new task"
else
    tmux new-window -d -t "$SESSION_NAME" -n "iss-$ISSUE" \
        "$SANDBOX_SH $WT listener"
    echo "[4/4] tmux window iss-$ISSUE spawned (listener)"
fi

echo
echo "Provisioned worker for issue #$ISSUE."
echo "  task_id: $TASK_ID"
echo "  worker: tmux window '$SESSION_NAME:iss-$ISSUE'"
echo "  monitor: ls $WT/.swarm/tasks/done/"
