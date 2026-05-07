#!/usr/bin/env bash
#
# worker-listener.sh — Asynchronous queue watcher for worker agents.
#
# Runs inside a worktree sandbox. Watches the per-worktree task queue at
# `.swarm/tasks/inbox/`, claims one task at a time via atomic mv to
# `processing/`, dispatches to the configured LLM agent, then writes a
# structured outcome JSON to `done/`. Polls every 2 seconds.
#
# Queue protocol (v2 — recommended):
#   <wt>/.swarm/tasks/inbox/<id>.md       coordinator writes here (atomic
#                                         via mktemp+mv); listener reads
#   <wt>/.swarm/tasks/processing/<id>.md  listener mv on pickup (atomic claim)
#   <wt>/.swarm/tasks/done/<id>.md        listener mv when finished (audit trail)
#   <wt>/.swarm/tasks/done/<id>.{ok,err}.json
#                                         listener writes structured outcome
#                                         (started/finished/duration/exit_code/agent/model)
#
# Coordinator polls done/*.json to know what happened (no need to scrape pane).
#
# Legacy single-file protocol (v1) — still supported for backward compat:
#   <wt>/.agent-task.md       drop a task brief here
#   <wt>/.agent-task-last.md  listener archives to here on pickup
#   (no structured outcome)
#
# Listener checks v2 queue first, falls back to v1 file. Both can be used.
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
HEADLESS="${WORKER_HEADLESS:-0}"

# Queue v2 directories (per-worktree)
QUEUE_ROOT=".swarm/tasks"
INBOX="$QUEUE_ROOT/inbox"
PROCESSING="$QUEUE_ROOT/processing"
DONE="$QUEUE_ROOT/done"
# blocked/ is the third terminal state (alongside ok/err) — agent writes
# .swarm/tasks/blocked/<task_id>.md to signal "stuck, needs human + context".
# See ADR-0002.
BLOCKED="$QUEUE_ROOT/blocked"
mkdir -p "$INBOX" "$PROCESSING" "$DONE" "$BLOCKED"

# Per-worktree label used in user-visible messages so it's obvious which
# worktree's inbox this listener is bound to (and that it does NOT serve
# briefs for other issues — those need their own provision-worker.sh /
# worktree). E.g. "wt-issue-215".
WT_LABEL="$(basename "$PWD")"

# Legacy v1 file
LEGACY_TASK_FILE=".agent-task.md"

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
echo "Worktree: $WT_LABEL  (this listener serves ONLY $WT_LABEL's inbox)"
echo "Agent:    $AGENT${MODEL:+ (model: $MODEL)}"
echo "Mode:     $([ "$HEADLESS" = "1" ] && echo headless || echo interactive)"
echo "Queue:    $INBOX/  →  $PROCESSING/  →  $DONE/"
echo "Legacy:   $LEGACY_TASK_FILE (v1, still supported)"
[ "$HEADLESS" = "1" ] || cat <<'NOTE'

  Interactive mode: agent will run the seeded prompt and then drop to
  its REPL. Attach with `tmux a -t <session>` and switch to this window
  to interact. On first run claude will ask "Trust this folder?" — say Y.
  When done, /quit (claude) or Ctrl-D (gemini) to release the listener
  for the next task. Set WORKER_HEADLESS=1 to disable.

NOTE
echo "------------------------------"

# Returns the path of the next task to process, or empty if none.
# Sets globals: TASK_PATH (where the brief now lives, after claim),
#               TASK_ID (identifier for this run),
#               IS_LEGACY (1 if v1, 0 if v2).
claim_next_task() {
    TASK_PATH=""
    TASK_ID=""
    IS_LEGACY=0

    # v2 queue: oldest non-tmp file in inbox
    local next_inbox
    next_inbox=$(find "$INBOX" -maxdepth 1 -type f -not -name '.tmp.*' 2>/dev/null \
                  | sort | head -1)
    if [ -n "$next_inbox" ]; then
        TASK_ID=$(basename "$next_inbox" .md)
        local target
        target="$PROCESSING/$(basename "$next_inbox")"
        # Atomic claim. If another process beat us to it, mv fails — try again.
        if mv "$next_inbox" "$target" 2>/dev/null; then
            TASK_PATH="$target"
            IS_LEGACY=0
            return 0
        fi
    fi

    # v1 legacy: single file in worktree root
    if [ -f "$LEGACY_TASK_FILE" ]; then
        # Atomic claim by renaming to a sentinel — we'll move to last.md after.
        local stash=".agent-task.md.processing.$$"
        if mv "$LEGACY_TASK_FILE" "$stash" 2>/dev/null; then
            TASK_PATH="$stash"
            TASK_ID="legacy-$(date +%s)-$$"
            IS_LEGACY=1
            return 0
        fi
    fi

    return 1
}

# Write a structured outcome record for v2 tasks. No-op for v1 (no contract).
# `blocked_arg` (5th arg) is "true" if a .swarm/tasks/blocked/<task_id>.md
# marker existed at outcome time — see ADR-0002. The `outcome` field stays
# binary (ok|err) for backward compat; `blocked` is a separate flag so
# pre-existing consumers that scan *.{ok,err}.json keep working.
write_outcome() {
    local rc="$1" started="$2" finished="$3" duration="$4" blocked_arg="${5:-false}"
    [ "$IS_LEGACY" = "1" ] && return 0

    local outcome="ok"
    [ "$rc" -ne 0 ] && outcome="err"
    local outcome_file="$DONE/${TASK_ID}.${outcome}.json"

    # JSON-escape the model field (may be empty)
    local model_json="null"
    [ -n "$MODEL" ] && model_json="\"$MODEL\""

    cat > "$outcome_file" <<EOF
{
  "task_id": "$TASK_ID",
  "started":  "$started",
  "finished": "$finished",
  "duration_seconds": $duration,
  "exit_code": $rc,
  "outcome": "$outcome",
  "blocked": $blocked_arg,
  "agent": "$AGENT",
  "model": $model_json,
  "headless": $([ "$HEADLESS" = "1" ] && echo true || echo false)
}
EOF
    echo "[$(date +%T)] Wrote outcome: $outcome_file"
}

while true; do
    if claim_next_task; then
        echo "[$(date +%T)] Task received! id=$TASK_ID$([ "$IS_LEGACY" = "1" ] && echo " (v1 legacy)")"

        TASK=$(cat "$TASK_PATH")

        # Echo the task brief so anyone attached can see what the worker is
        # actually working on. Truncate at 40 lines; full text always lives
        # in the processing/done file regardless.
        echo "--- Task brief (first 40 lines) ---"
        printf '%s\n' "$TASK" | head -40
        TASK_LINES=$(printf '%s\n' "$TASK" | wc -l)
        if [ "$TASK_LINES" -gt 40 ]; then
            echo "... [truncated; $TASK_LINES total lines] ..."
        fi
        echo "------------------------------------"

        echo "[$(date +%T)] Executing task..."
        STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        STARTED_EPOCH=$(date +%s)

        # Dispatch agent
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
        RC=$?

        FINISHED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        DURATION=$(( $(date +%s) - STARTED_EPOCH ))

        # Blocker handling (ADR-0002). If the agent wrote a marker before
        # exiting, surface it visibly. In headless mode, also auto-pivot
        # into an interactive `claude --continue` so a human attaching
        # later finds the full prior conversation reloaded — not a fresh
        # shell with the context already gone. In interactive (default)
        # mode, the agent's REPL has already happened, so we just leave
        # the marker in place as an observability signal.
        BLOCKED_MARKER=""
        WAS_BLOCKED="false"
        if [ "$IS_LEGACY" = "0" ]; then
            BLOCKED_MARKER="$BLOCKED/$TASK_ID.md"
            if [ -f "$BLOCKED_MARKER" ]; then
                WAS_BLOCKED="true"
                echo "════════════════════════════════════════════════════════"
                echo "[$(date +%T)] BLOCKED — agent wrote $BLOCKED_MARKER"
                echo "════════════════════════════════════════════════════════"
                cat "$BLOCKED_MARKER"
                echo "════════════════════════════════════════════════════════"
                if [ "$HEADLESS" = "1" ] && [ "$AGENT" = "claude" ]; then
                    echo "[$(date +%T)] Headless mode: auto-pivoting to \`claude --continue\`."
                    echo "                   Attach to this window; /quit when done."
                    echo "════════════════════════════════════════════════════════"
                    # The pivot itself can fail (e.g., session not found if
                    # claude state was wiped) — don't let that crash the
                    # listener. Capture rc but use the original RC for the
                    # outcome JSON; the outcome reflects the original task.
                    claude "${MODEL_OPTS[@]}" --continue --dangerously-skip-permissions || true
                    echo "════════════════════════════════════════════════════════"
                    echo "[$(date +%T)] Pivot session ended; resuming listener loop."
                    echo "════════════════════════════════════════════════════════"
                fi
            fi
        fi

        # Move brief into the appropriate archive location, then write outcome.
        if [ "$IS_LEGACY" = "1" ]; then
            mv "$TASK_PATH" ".agent-task-last.md"
        else
            mv "$TASK_PATH" "$DONE/$(basename "$TASK_PATH")"
            write_outcome "$RC" "$STARTED" "$FINISHED" "$DURATION" "$WAS_BLOCKED"
        fi

        echo "------------------------------"
        if [ "$WAS_BLOCKED" = "true" ]; then
            echo "[$(date +%T)] Task BLOCKED (exit $RC, ${DURATION}s). Marker: $BLOCKED_MARKER"
            echo "                   Coordinator-watch surfaces this; resolve by attaching, removing the marker, and using requeue.sh ${WT_LABEL#wt-issue-} <follow-up brief>."
        else
            echo "[$(date +%T)] Task complete (exit $RC, ${DURATION}s). Waiting for next brief in $WT_LABEL/$INBOX/ — use 'requeue.sh ${WT_LABEL#wt-issue-} <brief>' to send a follow-up on this issue. (Different issues need their own worktree via provision-worker.sh.)"
        fi
    fi
    sleep 2
done
