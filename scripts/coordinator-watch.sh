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

# --- Help / usage ---
case "${1:-}" in
    -h|--help)
        cat <<EOF
coordinator-watch.sh — Wake the coordinator on worker-finished events

USAGE
    coordinator-watch.sh [project-dir]

ARGUMENTS
    project-dir     Path to project root (default: \$PWD)

DESCRIPTION
    Long-running daemon. Watches every worker's .swarm/tasks/done/ dir
    under the workspace (parent of project-dir). When a new outcome JSON
    appears, wakes the coordinator via llm-start.sh so it can triage,
    re-dispatch, and top up workers.

CONFIG  (precedence: shell env > <project>/.swarm/.env > <sandbox>/.env.example)
    DEBOUNCE_SECS       30        coalesce window for repeat events
    POLL_SECS           2         poll-mode latency (when inotify absent)
    HEARTBEAT_SECS      60        periodic "still alive" line; 0 = silent
    DRY_RUN             0         log triggers, don't invoke llm-start.sh
    ONCE                0         exit after first wake (smoke-test)
    LLM_START           (auto)    override path to llm-start.sh
    WAKE_PROMPT         (top-up)  what the coordinator does on wake
    POST_OUTCOMES       0         run sweep-swarm-outcomes.sh per outcome
    OUTCOME_HOOK        (none)    path to per-outcome poster
    SWEEP               (auto)    override sweep-swarm-outcomes.sh path
    WORKSPACE           (auto)    parent dir for wt-issue-* worktrees
    MAX_WORKERS         2         (referenced by default WAKE_PROMPT)
    MAX_TMUX_WINDOWS    10        (referenced by default WAKE_PROMPT)

DEFAULT WAKE_PROMPT (top-up mode)
    Coordinator triages outcomes, then refills workers toward MAX_WORKERS
    (capped by MAX_TMUX_WINDOWS) using the @me-or-unassigned filter.
    Set WAKE_PROMPT explicitly to revert to triage-only behavior.

EVENTS LOG
    Appends to <project>/.swarm/events.log:
      watch.start    boot banner with backend + caps
      worker.finish  outcome JSON detected (issue, ok|err)
      coord.wake     llm-start.sh invoked (or coord.wake.skip on debounce)
      sweep.run      sweep-swarm-outcomes.sh fired (when POST_OUTCOMES=1)
      cap.refused    provision-worker.sh hit MAX_WORKERS / MAX_TMUX_WINDOWS

BACKEND
    Auto-detects inotifywait (instant) or falls back to polling find
    (POLL_SECS latency). Install inotify-tools for instant wakes.

EXAMPLES
    coordinator-watch.sh                                # watch \$PWD
    DRY_RUN=1 coordinator-watch.sh                      # log only, no wakes
    POST_OUTCOMES=1 OUTCOME_HOOK=/path coordinator-watch.sh   # + auditing
EOF
        exit 0
        ;;
esac

PROJECT_DIR="$(realpath "${1:-$PWD}")"
# Worker worktrees are siblings of PROJECT_DIR (provision-worker.sh creates
# them at <parent>/wt-issue-N), so the watch must scan the parent — not
# PROJECT_DIR itself. Override with WORKSPACE=<dir> for non-standard layouts.
WORKSPACE="$(realpath "${WORKSPACE:-$(dirname "$PROJECT_DIR")}")"
# Self-locate so defaults follow the script wherever it lives. LLM_START and
# SWEEP env overrides still win for non-standard installs.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_SANDBOX_DIR="${LLM_SANDBOX_DIR:-$(dirname "$SCRIPT_DIR")}"

# Apply <project>/.swarm/.env then sandbox .env.example before reading
# tunables, so caller env > project file > sandbox defaults. This script
# is normally inheriting from the tmux session env (set up by llm-start.sh),
# but the explicit load lets us run it standalone too.
# shellcheck source=_load-env.sh
. "$SCRIPT_DIR/_load-env.sh" "$PROJECT_DIR"

DEBOUNCE_SECS="${DEBOUNCE_SECS:-30}"
DRY_RUN="${DRY_RUN:-0}"
ONCE="${ONCE:-0}"
LLM_START="${LLM_START:-$LLM_SANDBOX_DIR/llm-start.sh}"
# Default wake prompt: top-up mode. The coordinator triages, then refills
# alive worker count toward MAX_WORKERS (subject to MAX_TMUX_WINDOWS) using
# the AVAILABLE filter defined in prompts/coordinator.md. To suppress
# auto-provisioning (old conservative default), set WAKE_PROMPT explicitly
# or invoke with INCLUDE_ASSIGNED_TO_OTHERS / triage-only language.
WAKE_PROMPT="${WAKE_PROMPT:-Worker(s) just finished. Triage their outcome JSONs in worktrees/.swarm/tasks/done/, then top up workers per the Initial Startup Checklist (compute AVAILABLE, count alive workers, fill open slots up to MAX_WORKERS subject to MAX_TMUX_WINDOWS). Use the @me-or-unassigned filter unless INCLUDE_ASSIGNED_TO_OTHERS=1.}"
POLL_SECS="${POLL_SECS:-2}"
HEARTBEAT_SECS="${HEARTBEAT_SECS:-60}"
POST_OUTCOMES="${POST_OUTCOMES:-0}"
SWEEP="${SWEEP:-$LLM_SANDBOX_DIR/scripts/sweep-swarm-outcomes.sh}"

# Append-only structured event log. Every observable event (start, outcome,
# wake, sweep, cap-refusal) gets a single line so `tail -F` gives live status.
EVENTS_LOG="$PROJECT_DIR/.swarm/events.log"
mkdir -p "$(dirname "$EVENTS_LOG")" 2>/dev/null || true

# log_event <category> <key=val>...
# Writes one line: "<utc-iso8601>  <category>  k=v k=v ..."
# Failures are non-fatal — log writes never break watcher work.
log_event() {
    local cat="$1"; shift
    local ts
    ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf '%s  %-15s %s\n' "$ts" "$cat" "$*" >> "$EVENTS_LOG" 2>/dev/null || true
}

# Validation
[ -d "$PROJECT_DIR" ] || { echo "ERROR: not a directory: $PROJECT_DIR" >&2; exit 1; }
[ -d "$WORKSPACE" ]   || { echo "ERROR: workspace not a directory: $WORKSPACE" >&2; exit 1; }
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
workspace:     $WORKSPACE (scanning $WORKSPACE/wt-issue-*/.swarm/tasks/done/)
backend:       $BACKEND$([ "$BACKEND" = "poll" ] && echo " (install inotify-tools for instant response)")
debounce:      ${DEBOUNCE_SECS}s
poll interval: ${POLL_SECS}s$([ "$BACKEND" = "inotify" ] && echo " (unused in inotify mode)")
heartbeat:     ${HEARTBEAT_SECS}s$([ "$HEARTBEAT_SECS" = "0" ] && echo " (disabled)")
llm-start.sh:  $LLM_START
post-outcomes: $POST_OUTCOMES$([ "$POST_OUTCOMES" = "1" ] && echo " (sweep: $SWEEP, hook: ${OUTCOME_HOOK:-default dry-run stub})")
events log:    $EVENTS_LOG  (tail -F for full history)
dry-run:       $DRY_RUN
once:          $ONCE

EOF
[ "$BACKEND" = "poll" ] && echo "Press Ctrl-C to stop. Polling every ${POLL_SECS}s for new outcome JSONs..." || \
    echo "Press Ctrl-C to stop. Listening for create/moved_to events..."
echo ""

log_event watch.start \
    "project=$PROJECT_DIR backend=$BACKEND debounce=${DEBOUNCE_SECS}s max_workers=${MAX_WORKERS:-?} max_tmux_windows=${MAX_TMUX_WINDOWS:-?}"

# Shared state
LAST_WAKE=0
LAST_OUTCOME_TS=0
LAST_OUTCOME_INFO="never"

# --- Heartbeat -------------------------------------------------------------
# Periodic "still alive" line so the pane isn't silent between events.
# State is shared with the backgrounded printer via a small file (the
# inotify backend's main loop runs inside a subshell pipeline, so on_outcome
# vars wouldn't otherwise be visible to a backgrounded child).
HB_STATE_FILE=""
HB_PID=""

if [ "$HEARTBEAT_SECS" -gt 0 ]; then
    HB_STATE_FILE=$(mktemp -t coord-watch-hb-XXXXXX)
    printf '0|never|0\n' > "$HB_STATE_FILE"
fi

# update_hb_state — called from on_outcome after LAST_OUTCOME_* / LAST_WAKE
# are updated; the printer reads the file each tick.
update_hb_state() {
    [ -n "$HB_STATE_FILE" ] || return 0
    printf '%s|%s|%s\n' "$LAST_OUTCOME_TS" "$LAST_OUTCOME_INFO" "$LAST_WAKE" \
        > "$HB_STATE_FILE" 2>/dev/null || true
}

# heartbeat_loop — backgrounded printer. Counts current outcome JSONs as
# a "tracked" gauge so you can see workers landing results in real time.
heartbeat_loop() {
    local now ts info wake_ts since_outcome since_wake tracked
    while sleep "$HEARTBEAT_SECS"; do
        [ -f "$HB_STATE_FILE" ] || break
        IFS='|' read -r ts info wake_ts < "$HB_STATE_FILE" || break
        now=$(date +%s)
        if [ "${ts:-0}" = "0" ]; then
            since_outcome="never"
        else
            since_outcome="$info"
        fi
        if [ "${wake_ts:-0}" = "0" ]; then
            since_wake="—"
        else
            since_wake="$((now - wake_ts))s ago"
        fi
        tracked=$(
            shopt -s nullglob
            files=("$WORKSPACE"/wt-issue-*/.swarm/tasks/done/*.ok.json \
                   "$WORKSPACE"/wt-issue-*/.swarm/tasks/done/*.err.json)
            echo "${#files[@]}"
        )
        # Blocked count: workers with a .swarm/tasks/blocked/<task_id>.md
        # marker present (per ADR-0002). Workers go quiet either because
        # they finished OR because they're stuck — the marker distinguishes
        # the two. Surface 'blocked=N' so the user knows when human attention
        # is needed vs. when an iss-* window is just idle-after-success.
        blocked_count=$(
            shopt -s nullglob
            markers=("$WORKSPACE"/wt-issue-*/.swarm/tasks/blocked/*.md)
            echo "${#markers[@]}"
        )
        printf '[%s] heartbeat — backend=%s last_outcome=%s since_wake=%s tracked=%s blocked=%s\n' \
            "$(date +%H:%M:%S)" "$BACKEND" "$since_outcome" "$since_wake" "$tracked" "$blocked_count"
    done
}

cleanup_hb() {
    [ -n "$HB_PID" ] && kill "$HB_PID" 2>/dev/null || true
    [ -n "$HB_STATE_FILE" ] && rm -f "$HB_STATE_FILE" || true
}

if [ "$HEARTBEAT_SECS" -gt 0 ]; then
    heartbeat_loop &
    HB_PID=$!
fi
trap cleanup_hb EXIT INT TERM

# Trigger logic — called when a NEW outcome JSON path is observed
on_outcome() {
    local path="$1"
    local now issue outcome
    now=$(date +%s)

    # Parse outcome filename: <task-id>-<issue>.<ok|err>.json
    issue=$(basename "$path" | sed -E 's/.*-([0-9]+)\.(ok|err)\.json$/\1/')
    case "$path" in
        *.ok.json)  outcome=ok ;;
        *.err.json) outcome=err ;;
        *)          outcome=unknown ;;
    esac
    log_event worker.finish "issue=$issue outcome=$outcome path=$path"

    LAST_OUTCOME_TS=$now
    LAST_OUTCOME_INFO="$(date +%H:%M:%S) (issue=$issue, $outcome)"
    update_hb_state

    # Audit posting fires for EVERY outcome (not gated by wake-debounce).
    # The sweep is idempotent via .posted markers, so repeated calls are
    # cheap, and we don't want auditing to be coalesced — every finished
    # task should get its comment posted.
    if [ "$POST_OUTCOMES" = "1" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            echo "[$(date +%T)] [DRY] would: $SWEEP $PROJECT_DIR"
            log_event sweep.dry "issue=$issue"
        else
            echo "[$(date +%T)] sweep: posting outcomes…"
            log_event sweep.run "issue=$issue"
            "$SWEEP" "$PROJECT_DIR" || {
                echo "[$(date +%T)] WARN: sweep returned non-zero (continuing watch)"
                log_event sweep.error "issue=$issue"
            }
        fi
    fi

    if [ $((now - LAST_WAKE)) -lt "$DEBOUNCE_SECS" ]; then
        echo "[$(date +%T)] outcome: $path — within debounce window (${DEBOUNCE_SECS}s), skipping wake"
        log_event coord.wake.skip "issue=$issue reason=debounce window=${DEBOUNCE_SECS}s"
        return
    fi

    echo "[$(date +%T)] outcome: $path"
    echo "[$(date +%T)] waking coordinator..."
    log_event coord.wake "issue=$issue trigger=$(basename "$path")"

    if [ "$DRY_RUN" = "1" ]; then
        echo "[DRY] would: cd $PROJECT_DIR && NON_INTERACTIVE=1 $LLM_START \"$WAKE_PROMPT\""
    else
        # Run llm-start.sh in a subshell so its `set -e` doesn't kill us.
        # NON_INTERACTIVE=1 prevents auto-attach; coordinator runs detached
        # in its tmux session.
        ( cd "$PROJECT_DIR" && NON_INTERACTIVE=1 "$LLM_START" "$WAKE_PROMPT" ) || {
            echo "[$(date +%T)] WARN: coordinator wake exited non-zero (continuing watch)"
            log_event coord.wake.error "issue=$issue"
        }
    fi
    LAST_WAKE=$now
    update_hb_state

    if [ "$ONCE" = "1" ]; then
        echo "[$(date +%T)] ONCE=1 — exiting after first wake."
        log_event watch.exit "reason=once"
        exit 0
    fi
}

# on_blocked — called when a new .swarm/tasks/blocked/<task_id>.md marker
# is observed (either backend). Logs the event; does NOT trigger a wake
# because the human, not the coordinator, is the resolver. The blocked
# count appears in the next heartbeat naturally.
on_blocked() {
    local path="$1"
    local issue
    # path: <workspace>/wt-issue-<N>/.swarm/tasks/blocked/<task_id>.md
    # → 4 dirnames to reach wt-issue-<N>; basename then strips wt-issue- prefix
    issue=$(basename "$(dirname "$(dirname "$(dirname "$(dirname "$path")")")")" | sed 's/^wt-issue-//')
    log_event worker.blocked "issue=$issue path=$path"
    echo "[$(date +%T)] worker.blocked — issue=$issue marker=$path"
}

# ---------------------------------------------------------------------------
# Backend: inotify
# ---------------------------------------------------------------------------
run_inotify() {
    # Watch the workspace (parent of project) recursively, filtering events
    # to only outcomes inside wt-issue-*/.swarm/tasks/done/. The listener
    # does `mv processing/X.md done/X.md` followed by writing done/X.json —
    # both surface as create/moved_to events.
    #
    # --exclude noisy dirs to keep watch count low.
    inotifywait -m -r \
        --exclude '/(\.git|node_modules|build|target|\.gradle|dist|out|\.next|\.venv|venv)(/|$)' \
        -e create -e moved_to \
        --format '%w%f' \
        "$WORKSPACE" 2>/dev/null \
    | while IFS= read -r path; do
        case "$path" in
            */wt-issue-*/.swarm/tasks/done/*.ok.json|*/wt-issue-*/.swarm/tasks/done/*.err.json)
                on_outcome "$path"
                ;;
            */wt-issue-*/.swarm/tasks/blocked/*.md)
                on_blocked "$path"
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
    # Merge with the global cleanup_hb trap; bare `trap CMD SIG` would
    # replace it and leak the heartbeat subshell + state file on Ctrl-C.
    # Guard $seen_file with :- because EXIT trap may fire after the
    # function returns (local var out of scope), which would trip set -u.
    trap '[ -n "${seen_file:-}" ] && rm -f "$seen_file"; cleanup_hb' EXIT INT TERM

    # Scan only wt-issue-*/.swarm/tasks/done dirs under WORKSPACE. The glob
    # may expand to nothing if no worker worktrees exist yet — handle that
    # gracefully via nullglob so the find call gets an empty arg list.
    scan_outcomes() {
        local done_dirs=() blocked_dirs=()
        shopt -s nullglob
        done_dirs=("$WORKSPACE"/wt-issue-*/.swarm/tasks/done)
        blocked_dirs=("$WORKSPACE"/wt-issue-*/.swarm/tasks/blocked)
        shopt -u nullglob
        if [ "${#done_dirs[@]}" -eq 0 ] && [ "${#blocked_dirs[@]}" -eq 0 ]; then
            return 0   # no worker worktrees — emit empty
        fi
        # Outcome JSONs and blocked markers share the same poll set; the
        # dispatcher below routes by suffix.
        {
            [ "${#done_dirs[@]}" -gt 0 ] && find "${done_dirs[@]}" -maxdepth 1 \
                \( -name '*.ok.json' -o -name '*.err.json' \) -print 2>/dev/null
            [ "${#blocked_dirs[@]}" -gt 0 ] && find "${blocked_dirs[@]}" -maxdepth 1 \
                -name '*.md' -print 2>/dev/null
        } | sort -u
    }

    scan_outcomes > "$seen_file"

    while true; do
        local current diff_new
        current=$(scan_outcomes)

        # New paths = in current, not in seen. Guard against the shutdown
        # race where the EXIT trap removes seen_file mid-iteration.
        [ -f "$seen_file" ] || break
        diff_new=$(comm -23 <(echo "$current") "$seen_file" 2>/dev/null || true)
        if [ -n "$diff_new" ]; then
            while IFS= read -r path; do
                [ -z "$path" ] && continue
                case "$path" in
                    */tasks/done/*.ok.json|*/tasks/done/*.err.json) on_outcome "$path" ;;
                    */tasks/blocked/*.md)                          on_blocked "$path" ;;
                esac
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
