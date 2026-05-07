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

# --- Help / usage ---
case "${1:-}" in
    -h|--help)
        cat <<EOF
provision-worker.sh — Provision a worker for one GitHub issue

USAGE
    provision-worker.sh <issue-number> [project-dir]

ARGUMENTS
    issue-number    GitHub issue number to dispatch (required)
    project-dir     Path to project root (default: \$PWD)

DESCRIPTION
    One-call helper for the coordinator. Creates worktree at
    <parent>/wt-issue-N on branch fix/issue-N (idempotent), initializes
    the v2 queue, embeds .swarm-policy.md guardrails into the brief,
    atomic-writes the task into inbox/, and spawns a worker tmux window
    'iss-N' running the sandbox listener.

CAP ENFORCEMENT (exit 3 on either)
    MAX_WORKERS         alive iss-* windows < cap         (default 2)
    MAX_TMUX_WINDOWS    total session windows < cap       (default 10)
    Both are checked just before the new tmux window would be created.
    Re-running for an existing iss-N window does NOT count against caps —
    that path queues a follow-up task without adding capacity.

CONFIG  (precedence: shell env > <project>/.swarm/.env > <sandbox>/.env.example)
    MAX_WORKERS         2         worker tmux window cap
    MAX_TMUX_WINDOWS    10        total session window cap
    SANDBOX_SH          (auto)    path to sandbox.sh used by the listener
    LLM_SANDBOX_DIR     (auto)    sandbox install dir

EVENTS LOG
    Appends to <project>/.swarm/events.log:
      worker.start     new iss-N window created (alive=A/MAX, total=W/MAX)
      worker.requeue   existing iss-N window reused for follow-up task
      cap.refused      MAX_WORKERS or MAX_TMUX_WINDOWS would be exceeded

EXAMPLES
    provision-worker.sh 142                 # dispatch issue #142 from \$PWD
    provision-worker.sh 142 /path/to/proj   # explicit project dir
EOF
        exit 0
        ;;
esac

ISSUE="${1:?usage: provision-worker.sh <issue-number> [project-dir]   (try --help)}"
PROJECT_DIR="${2:-$PWD}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
WT="$(dirname "$PROJECT_DIR")/wt-issue-$ISSUE"
BRANCH="fix/issue-$ISSUE"
SESSION_NAME="llm-$(basename "$PROJECT_DIR")"
# Self-locate so SANDBOX_SH default follows the script. Override with
# SANDBOX_SH=<path> when running a non-standard install.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_SANDBOX_DIR="${LLM_SANDBOX_DIR:-$(dirname "$SCRIPT_DIR")}"
SANDBOX_SH="${SANDBOX_SH:-$LLM_SANDBOX_DIR/sandbox.sh}"

# Apply <project>/.swarm/.env then sandbox .env.example before reading caps,
# so caller env > project file > sandbox defaults. Normally the tmux session
# already has these exported (set by llm-start.sh), but the explicit load
# lets the script run correctly when invoked standalone.
# shellcheck source=_load-env.sh
. "$SCRIPT_DIR/_load-env.sh" "$PROJECT_DIR"

MAX_WORKERS="${MAX_WORKERS:-5}"
MAX_TMUX_WINDOWS="${MAX_TMUX_WINDOWS:-10}"

# Append-only structured event log. Same format as coordinator-watch.sh.
EVENTS_LOG="$PROJECT_DIR/.swarm/events.log"
mkdir -p "$(dirname "$EVENTS_LOG")" 2>/dev/null || true
log_event() {
    local cat="$1"; shift
    local ts
    ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf '%s  %-15s %s\n' "$ts" "$cat" "$*" >> "$EVENTS_LOG" 2>/dev/null || true
}

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
#
# TASK_ID base is second-resolution; on the rare case of two re-dispatches
# in the same wall-clock second for the same issue, append a counter
# (-2, -3, ...) so we don't silently clobber the previous brief. The common
# case (no collision) keeps the clean YYYYMMDD-HHMMSS-N naming.
BASE_ID="$(date +%Y%m%d-%H%M%S)-$ISSUE"
TASK_ID="$BASE_ID"
DEST="$WT/.swarm/tasks/inbox/$TASK_ID.md"
N=2
while [ -e "$DEST" ]; do
    TASK_ID="$BASE_ID-$N"
    DEST="$WT/.swarm/tasks/inbox/$TASK_ID.md"
    N=$((N + 1))
done

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
    cat <<EOF
## Completion Protocol

When the issue's acceptance criteria are met:

1. Stage and commit your changes on the current branch (\`fix/issue-$ISSUE\`).
   Group related changes into one logical commit; multiple commits are fine
   if the work has natural boundaries.
2. Push the branch: \`git push -u origin fix/issue-$ISSUE\`.
3. Open a PR: \`gh pr create --title "..." --body "..."\`. Body MUST include
   \`Fixes #$ISSUE\` so the issue auto-closes on merge.
4. Stop there. Do NOT merge, do NOT close the issue, do NOT delete the branch
   — those are the human reviewer's steps.

## Blocker Escalation

If you cannot finish autonomously — environment broken, ambiguous acceptance
criteria, missing context the brief did not supply, design decision needed,
the issue's premises don't match the code as it actually is, etc. — DO NOT
invent answers, widen scope, or open a half-baked "TODO: figure out X" PR.

Instead:

1. Write \`.swarm/tasks/blocked/$TASK_ID.md\` with:
   - **Top of file:** the specific question(s) or what you'd need to proceed.
     Be concrete — "should the loader accept None or raise?" beats "what
     should I do here?".
   - **Below:** what you tried, what you discovered, the relevant file:line
     references, and any partial work-in-progress findings.
2. If you have committable partial work that's safe to keep (e.g. a passing
   test that isolates the unclear case), commit it on a \`wip/issue-$ISSUE\`
   branch and push. DO NOT open a PR for WIP.
3. Exit (claude /quit or just stop). The listener will reload your full
   conversation via \`claude --continue\` when a human is ready to resume —
   you don't need to re-summarize context, just write the blocker file and
   stop.

The presence of \`.swarm/tasks/blocked/$TASK_ID.md\` is the signal that gets
this worker surfaced in coordinator heartbeats as needing human attention.
Without that file, a stuck worker looks identical to a successful one.

---

## Task

Fix issue #$ISSUE. Details follow.

EOF
    gh issue view "$ISSUE"
} > "$TMP"
# `mv -n` won't clobber even if a colliding file appeared between our
# existence check and now; on the (vanishingly rare) race, fall back to
# bumping the counter and retrying once.
if ! mv -n "$TMP" "$DEST" 2>/dev/null || [ -f "$TMP" ]; then
    TASK_ID="$BASE_ID-$N"
    DEST="$WT/.swarm/tasks/inbox/$TASK_ID.md"
    mv "$TMP" "$DEST"
fi
echo "[3/4] brief queued: $DEST"

# 4. Spawn worker tmux window (background — does NOT steal focus from coordinator)
# If the session doesn't exist, fail clearly — the coordinator should be
# running inside the session, so it should always exist by the time we
# reach this script.
if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "ERROR: tmux session '$SESSION_NAME' does not exist." >&2
    echo "  (Are you running this from inside the coordinator's session?)" >&2
    exit 2
fi

# Skip if a window for this issue already exists — caps don't apply
# because we're not adding capacity, just queueing a follow-up task.
if tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep -qx "iss-$ISSUE"; then
    echo "[4/4] tmux window iss-$ISSUE already exists — listener will pick up the new task"
    log_event worker.requeue "issue=$ISSUE task_id=$TASK_ID"
else
    # Cap enforcement: count alive workers (iss-*) and total windows BEFORE
    # the spawn. Refuse with exit 3 if either cap would be exceeded. The
    # coordinator catches non-zero exits and reports back to the user.
    alive_workers=$(tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep -c '^iss-' || true)
    total_windows=$(tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | wc -l)
    if [ "$alive_workers" -ge "$MAX_WORKERS" ]; then
        echo "ERROR: MAX_WORKERS cap reached (alive=$alive_workers, max=$MAX_WORKERS)" >&2
        echo "       Wait for a worker to finish, or raise MAX_WORKERS in <project>/.swarm/.env." >&2
        log_event cap.refused "issue=$ISSUE reason=max_workers alive=$alive_workers max=$MAX_WORKERS"
        exit 3
    fi
    if [ "$total_windows" -ge "$MAX_TMUX_WINDOWS" ]; then
        echo "ERROR: MAX_TMUX_WINDOWS cap reached (total=$total_windows, max=$MAX_TMUX_WINDOWS)" >&2
        echo "       Close finished iss-* windows: tmux kill-window -t '$SESSION_NAME:iss-NN'" >&2
        echo "       Or raise MAX_TMUX_WINDOWS in <project>/.swarm/.env." >&2
        log_event cap.refused "issue=$ISSUE reason=max_tmux_windows total=$total_windows max=$MAX_TMUX_WINDOWS"
        exit 3
    fi

    tmux new-window -d -t "$SESSION_NAME" -n "iss-$ISSUE" \
        "$SANDBOX_SH $WT listener"
    echo "[4/4] tmux window iss-$ISSUE spawned (listener)"
    log_event worker.start "issue=$ISSUE task_id=$TASK_ID window=iss-$ISSUE alive=$((alive_workers + 1))/$MAX_WORKERS total_windows=$((total_windows + 1))/$MAX_TMUX_WINDOWS"
fi

echo
echo "Provisioned worker for issue #$ISSUE."
echo "  task_id: $TASK_ID"
echo "  worker: tmux window '$SESSION_NAME:iss-$ISSUE'"
echo "  monitor: ls $WT/.swarm/tasks/done/"
echo "  events:  tail -F $EVENTS_LOG"
