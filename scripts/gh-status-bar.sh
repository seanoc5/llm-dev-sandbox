#!/usr/bin/env bash
#
# gh-status-bar.sh — periodically pipe gh counts into tmux's status-right.
#
# Long-running daemon. Every $STATUS_INTERVAL seconds, queries:
#   - open issues
#   - open PRs
#   - PRs closed today
# …and updates the tmux session's `status-right` string. Visible from every
# window in the session (coordinator, watch, iss-N) without polluting the
# event log.
#
# Usage:
#   gh-status-bar.sh <session-name> [project-dir]
#
# Env vars:
#   STATUS_INTERVAL=60       Refresh interval in seconds. ≥30s recommended
#                            (gh is rate-limited at 5000/hr; 3 calls per
#                            refresh × 60/min = 180/hr — well under).
#   STATUS_LENGTH=120        tmux status-right-length. Bumped from default 40
#                            so the counts + clock fit.
#   STATUS_FORMAT=<template> Override the rendered string. Available
#                            placeholders: <iss> <pr> <today> <time>.
#                            (Angle brackets used to avoid conflicting with
#                            bash's ${...} parameter expansion when the
#                            default value is set inline below.)
#   GH_TIMEOUT=10            Per-gh-call timeout in seconds. Slow API
#                            shouldn't block the loop.
#
# Lifecycle:
#   - Self-exits cleanly when the tmux session disappears (set-option fails).
#   - Resets status-right to empty on EXIT/INT/TERM so the bar isn't left
#     showing stale numbers after the daemon dies.
set -euo pipefail

SESSION_NAME="${1:?usage: gh-status-bar.sh <session-name> [project-dir]}"
PROJECT_DIR="${2:-$PWD}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

STATUS_INTERVAL="${STATUS_INTERVAL:-60}"
STATUS_LENGTH="${STATUS_LENGTH:-120}"
GH_TIMEOUT="${GH_TIMEOUT:-10}"
# Tmux #[...] color blocks are passed literally — tmux interprets them at
# render time. <iss>/<pr>/<today>/<time> are substituted by us. Angle
# brackets (not braces) so the literal default below doesn't get eaten
# by bash's ${...} parameter expansion.
STATUS_FORMAT="${STATUS_FORMAT:-#[fg=cyan]iss:<iss> #[fg=green]pr:<pr> #[fg=yellow]closed-today:<today> #[fg=default]<time> }"

# --- Validation --------------------------------------------------------------
command -v gh >/dev/null   || { echo "ERROR: gh not on PATH"   >&2; exit 1; }
command -v tmux >/dev/null || { echo "ERROR: tmux not on PATH" >&2; exit 1; }
command -v jq >/dev/null   || { echo "ERROR: jq not on PATH"   >&2; exit 1; }

if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "ERROR: tmux session '$SESSION_NAME' does not exist" >&2
    exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
    echo "ERROR: gh not authenticated. Run 'gh auth login' first." >&2
    exit 1
fi

# --- Cleanup -----------------------------------------------------------------
cleanup() {
    # Best-effort reset; ignore errors if session is already gone.
    tmux set-option -t "$SESSION_NAME" status-right "" 2>/dev/null || true
}
# EXIT runs cleanup on any exit (normal, error, signal-after-handler).
# INT/TERM additionally trigger an immediate exit so we don't sit in
# `sleep $STATUS_INTERVAL` for up to a minute after the user kills us.
trap cleanup EXIT
trap 'exit 0' INT TERM

# --- Banner ------------------------------------------------------------------
cat <<EOF
=== gh-status-bar.sh ===
session:    $SESSION_NAME
project:    $PROJECT_DIR
interval:   ${STATUS_INTERVAL}s
length:     ${STATUS_LENGTH}
gh timeout: ${GH_TIMEOUT}s
format:     $STATUS_FORMAT

EOF

# Bump status-right-length once at startup so our counts fit.
tmux set-option -t "$SESSION_NAME" status-right-length "$STATUS_LENGTH" 2>/dev/null || true

# --- Helpers -----------------------------------------------------------------
# gh + jq with a timeout so a slow API doesn't stall the loop. Returns "?" on
# any failure — the caller renders that, so the bar shows "?" instead of
# stale digits when the API is down.
gh_count() {
    local out
    if out=$(timeout "$GH_TIMEOUT" "$@" --json number 2>/dev/null) && [ -n "$out" ]; then
        echo "$out" | jq 'length' 2>/dev/null || echo "?"
    else
        echo "?"
    fi
}

render_status() {
    local iss="$1" pr="$2" today="$3"
    local now
    now=$(date +%H:%M)
    # Bash native string substitution. Order doesn't matter — placeholders
    # don't overlap.
    local out="$STATUS_FORMAT"
    out="${out//<iss>/$iss}"
    out="${out//<pr>/$pr}"
    out="${out//<today>/$today}"
    out="${out//<time>/$now}"
    echo "$out"
}

# --- Main loop ---------------------------------------------------------------
cd "$PROJECT_DIR"
echo "Press Ctrl-C to stop."

while true; do
    today_date="$(date -I)"
    open_iss=$(gh_count gh issue list -s open -L 1000)
    open_pr=$(gh_count gh pr list -s open -L 1000)
    closed_today=$(gh_count gh pr list -s closed -L 1000 --search "closed:>=$today_date")

    rendered=$(render_status "$open_iss" "$open_pr" "$closed_today")

    if ! tmux set-option -t "$SESSION_NAME" status-right "$rendered" 2>/dev/null; then
        echo "[$(date +%T)] tmux session '$SESSION_NAME' gone — exiting."
        exit 0
    fi

    # Light heartbeat to stdout so users tailing the pane can see it's alive.
    echo "[$(date +%T)] iss:$open_iss pr:$open_pr closed-today:$closed_today"

    sleep "$STATUS_INTERVAL"
done
