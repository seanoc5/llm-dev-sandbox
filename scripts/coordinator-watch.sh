#!/usr/bin/env bash
#
# coordinator-watch.sh — wake the coordinator on worker-finished events.
#
# Long-running daemon. Watches every worker's `.swarm/tasks/done/` dir
# under the given project. When a new outcome JSON appears there (i.e. a
# worker finished a task), wakes the coordinator via `llm-start.sh` so
# it can triage / re-dispatch / merge / etc.
#
# Pairs with the queued protocol from worker-listener.sh — proves the
# "event-driven coordinator" upgrade path described in the README.
#
# Usage:
#   coordinator-watch.sh [project-dir]
#
# Env vars:
#   DEBOUNCE_SECS=30        Window during which repeated events coalesce
#                           into a single coordinator wake. Prevents runaway
#                           when many workers finish near-simultaneously.
#   DRY_RUN=0               Set to 1 to log what would happen without
#                           actually invoking llm-start.sh.
#   ONCE=0                  Set to 1 to exit after first successful wake.
#                           Useful for smoke-testing.
#   LLM_START=<path>        Override path to llm-start.sh.
#   WAKE_PROMPT=<text>      Prompt sent to the coordinator on wake.
#   POLL_SECS=2             Polling interval (used only in polling-mode
#                           fallback when inotifywait is unavailable).
#   POST_OUTCOMES=0         Set to 1 to also run sweep-swarm-outcomes.sh
#                           on each detected outcome. Posting is naturally
#                           idempotent via .posted markers, so this fires
#                           outside the wake-debounce window — every
#                           outcome gets audit coverage even when wakes
#                           are coalesced. Honors $OUTCOME_HOOK; falls
#                           back to dry-run stub if unset.
#   SWEEP=<path>            Override path to sweep-swarm-outcomes.sh.
#
# Watch backend (auto-detected):
#   - inotifywait (preferred): instant response. Install with:
#       sudo apt install inotify-tools
#     and bump inotify watches if you watch large repos:
#       sudo sysctl fs.inotify.max_user_watches=524288
#   - polling find (fallback): ~2s latency. No dependencies.

set -euo pipefail

PROJECT_DIR="$(realpath "${1:-$PWD}")"
DEBOUNCE_SECS="${DEBOUNCE_SECS:-30}"
DRY_RUN="${DRY_RUN:-0}"
ONCE="${ONCE:-0}"
LLM_START="${LLM_START:-/opt/work/sysadmin/llm-dev-sandbox/llm-start.sh}"
WAKE_PROMPT="${WAKE_PROMPT:-Worker(s) just finished. Triage their outcome JSONs in worktrees/.swarm/tasks/done/ and decide next actions. Do NOT dispatch new workers unless the user asked you to.}"
POLL_SECS="${POLL_SECS:-2}"
POST_OUTCOMES="${POST_OUTCOMES:-0}"
SWEEP="${SWEEP:-/opt/work/sysadmin/llm-dev-sandbox/scripts/sweep-swarm-outcomes.sh}"

# Validation
[ -d "$PROJECT_DIR" ] || { echo "ERROR: not a directory: $PROJECT_DIR" >&2; exit 1; }
[ -x "$LLM_START" ]   || { echo "ERROR: llm-start.sh not executable: $LLM_START" >&2; exit 1; }
if [ "$POST_OUTCOMES" = "1" ]; then
    [ -x "$SWEEP" ] || { echo "ERROR: sweep script not executable: $SWEEP" >&2; exit 1; }
fi

# Pick a backend
BACKEND="poll"
if command -v inotifywait >/dev/null 2>&1; then
    BACKEND="inotify"
fi

# Banner
cat <<EOF
=== coordinator-watch.sh ===
project:       $PROJECT_DIR
backend:       $BACKEND$([ "$BACKEND" = "poll" ] && echo " (install inotify-tools for instant response)")
debounce:      ${DEBOUNCE_SECS}s
poll interval: ${POLL_SECS}s$([ "$BACKEND" = "inotify" ] && echo " (unused in inotify mode)")
llm-start.sh:  $LLM_START
post-outcomes: $POST_OUTCOMES$([ "$POST_OUTCOMES" = "1" ] && echo " (sweep: $SWEEP, hook: ${OUTCOME_HOOK:-default dry-run stub})")
dry-run:       $DRY_RUN
once:          $ONCE

EOF
[ "$BACKEND" = "poll" ] && echo "Press Ctrl-C to stop. Polling every ${POLL_SECS}s for new outcome JSONs..." || \
    echo "Press Ctrl-C to stop. Listening for create/moved_to events..."
echo ""

# Shared state
LAST_WAKE=0

# Trigger logic — called when a NEW outcome JSON path is observed
on_outcome() {
    local path="$1"
    local now
    now=$(date +%s)

    # Audit posting fires for EVERY outcome (not gated by wake-debounce).
    # The sweep is idempotent via .posted markers, so repeated calls are
    # cheap, and we don't want auditing to be coalesced — every finished
    # task should get its comment posted.
    if [ "$POST_OUTCOMES" = "1" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            echo "[$(date +%T)] [DRY] would: $SWEEP $PROJECT_DIR"
        else
            echo "[$(date +%T)] sweep: posting outcomes…"
            "$SWEEP" "$PROJECT_DIR" || echo "[$(date +%T)] WARN: sweep returned non-zero (continuing watch)"
        fi
    fi

    if [ $((now - LAST_WAKE)) -lt "$DEBOUNCE_SECS" ]; then
        echo "[$(date +%T)] outcome: $path — within debounce window (${DEBOUNCE_SECS}s), skipping wake"
        return
    fi

    echo "[$(date +%T)] outcome: $path"
    echo "[$(date +%T)] waking coordinator..."

    if [ "$DRY_RUN" = "1" ]; then
        echo "[DRY] would: cd $PROJECT_DIR && NON_INTERACTIVE=1 $LLM_START \"$WAKE_PROMPT\""
    else
        # Run llm-start.sh in a subshell so its `set -e` doesn't kill us.
        # NON_INTERACTIVE=1 prevents auto-attach; coordinator runs detached
        # in its tmux session.
        ( cd "$PROJECT_DIR" && NON_INTERACTIVE=1 "$LLM_START" "$WAKE_PROMPT" ) || \
            echo "[$(date +%T)] WARN: coordinator wake exited non-zero (continuing watch)"
    fi
    LAST_WAKE=$now

    if [ "$ONCE" = "1" ]; then
        echo "[$(date +%T)] ONCE=1 — exiting after first wake."
        exit 0
    fi
}

# ---------------------------------------------------------------------------
# Backend: inotify
# ---------------------------------------------------------------------------
run_inotify() {
    # Watch project root recursively for create + moved_to events.
    # The listener does `mv processing/X.md done/X.md` followed by writing
    # done/X.json — both surface as create/moved_to events. We filter to
    # only outcome JSONs in worker done dirs.
    #
    # --exclude noisy dirs to keep watch count low.
    inotifywait -m -r \
        --exclude '/(\.git|node_modules|build|target|\.gradle|dist|out|\.next|\.venv|venv)(/|$)' \
        -e create -e moved_to \
        --format '%w%f' \
        "$PROJECT_DIR" 2>/dev/null \
    | while IFS= read -r path; do
        case "$path" in
            */.swarm/tasks/done/*.ok.json|*/.swarm/tasks/done/*.err.json)
                on_outcome "$path"
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Backend: polling (find)
# ---------------------------------------------------------------------------
run_poll() {
    # Build a baseline of currently-known outcome JSONs so we don't fire
    # for anything that existed before the watcher started.
    local seen_file
    seen_file=$(mktemp -t coord-watch-seen-XXXXXX)
    trap 'rm -f "$seen_file"' EXIT INT TERM

    find "$PROJECT_DIR" \( -name node_modules -o -name .git -o -name build -o -name target -o -name .gradle \) -prune \
        -o -path '*/.swarm/tasks/done/*.ok.json' -print \
        -o -path '*/.swarm/tasks/done/*.err.json' -print 2>/dev/null \
        | sort -u > "$seen_file"

    while true; do
        local current diff_new
        current=$(find "$PROJECT_DIR" \( -name node_modules -o -name .git -o -name build -o -name target -o -name .gradle \) -prune \
            -o -path '*/.swarm/tasks/done/*.ok.json' -print \
            -o -path '*/.swarm/tasks/done/*.err.json' -print 2>/dev/null \
            | sort -u)

        # New paths = in current, not in seen. Guard against the shutdown
        # race where the EXIT trap removes seen_file mid-iteration.
        [ -f "$seen_file" ] || break
        diff_new=$(comm -23 <(echo "$current") "$seen_file" 2>/dev/null || true)
        if [ -n "$diff_new" ]; then
            while IFS= read -r path; do
                [ -z "$path" ] && continue
                on_outcome "$path"
            done <<< "$diff_new"
            echo "$current" > "$seen_file"
        fi

        sleep "$POLL_SECS"
    done
}

case "$BACKEND" in
    inotify) run_inotify ;;
    poll)    run_poll ;;
esac
