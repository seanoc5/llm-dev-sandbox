#!/usr/bin/env bash
#
# llm-start.sh - Bootstrap the multi-agent tmux session
#
# This script creates a dedicated tmux session for the current project,
# spawns the Gemini Coordinator agent in the first window, and issues
# its initial startup command.
set -euo pipefail

# Configuration
SESSION_NAME="llm-$(basename "$PWD")"
SYSTEM_PROMPT_FILE="/opt/work/sysadmin/llm-dev-sandbox/prompts/coordinator.md"
INITIAL_PROMPT="${1:-Execute the Initial Startup Checklist.}"

# Allow overriding the coordinator command and model
COORD_CMD="${COORDINATOR_CMD:-gemini}"
# gemini-2.5-flash is stable; gemini-3-flash-preview returns INVALID_ARGUMENT
# ("Please ensure that function response turn comes immediately after a function
# call turn") on multi-step tool sequences, which is the coordinator's whole
# job. Override with COORDINATOR_MODEL=gemini-3-flash-preview when re-testing.
COORD_MODEL="${COORDINATOR_MODEL:-gemini-2.5-flash}"

# Auto-discover GEMINI_API_KEY when running gemini coordinator. Gemini CLI only
# auto-loads .env from CWD/walks up to $HOME and ~/.gemini/.env — it never
# finds keys stored in the sysadmin repo. So we walk a known list and source
# the first match into our env. tmux new-session -e then propagates it into
# the coordinator pane.
GEMINI_ENV_SOURCED=""
if [ "$COORD_CMD" = "gemini" ] && [ -z "${GEMINI_API_KEY:-}" ]; then
    for _candidate in \
        "$PWD/.env" \
        "$HOME/.gemini/.env" \
        "/opt/work/sysadmin/llm-dev-sandbox/.env" \
        "/opt/work/sysadmin/.env"; do
        if [ -f "$_candidate" ] && grep -q '^GEMINI_API_KEY=' "$_candidate" 2>/dev/null; then
            # shellcheck disable=SC1090
            set -a; . "$_candidate"; set +a
            if [ -n "${GEMINI_API_KEY:-}" ]; then
                GEMINI_ENV_SOURCED="$_candidate"
                break
            fi
        fi
    done
    if [ -z "${GEMINI_API_KEY:-}" ]; then
        echo "WARN: GEMINI_API_KEY not in env and not found in any of:" >&2
        echo "      \$PWD/.env, ~/.gemini/.env, /opt/work/sysadmin/llm-dev-sandbox/.env, /opt/work/sysadmin/.env" >&2
        echo "      gemini will fail with 'specify the GEMINI_API_KEY' on launch." >&2
    fi
fi

# Check if already inside tmux
IN_TMUX=false
if [ -n "${TMUX:-}" ]; then
    IN_TMUX=true
fi

# --- Session + coordinator-pane state detection -----------------------------
# Two boolean flags drive the launch decision below:
#   session_existed      — was a prior llm-X session already running?
#   coordinator_idle     — is the coordinator window's pane sitting at a shell
#                          prompt (i.e., previous agent exited / errored / Ctrl-C'd)?
# Logic:
#   • no session              → create new session + window, send prompt
#   • session, idle pane      → reuse existing window, send new prompt
#   • session, busy pane      → don't disturb; just attach so user can watch
session_existed=false
coordinator_idle=true
PANE_CMD=""
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    session_existed=true
    PANE_CMD=$(tmux list-panes -t "$SESSION_NAME:coordinator" -F "#{pane_current_command}" 2>/dev/null | head -1)
    case "$PANE_CMD" in
        bash|zsh|sh|fish|"") coordinator_idle=true ;;
        *)                   coordinator_idle=false ;;
    esac
fi

if ! $session_existed; then
    if [ "$COORD_CMD" = "gemini" ]; then
        echo "Creating new multi-agent session: $SESSION_NAME (Coordinator: gemini, Model: $COORD_MODEL)"
    else
        echo "Creating new multi-agent session: $SESSION_NAME (Coordinator: $COORD_CMD)"
    fi

    # Create a detached session, name the first window "coordinator".
    # Propagate GEMINI_API_KEY into the session env when present, so the
    # gemini coordinator (which auto-loads .env from CWD/walks up only)
    # finds it without us having to copy a .env into every project dir.
    TMUX_ENV_OPTS=()
    if [ -n "${GEMINI_API_KEY:-}" ]; then
        TMUX_ENV_OPTS+=(-e "GEMINI_API_KEY=$GEMINI_API_KEY")
    fi
    # Propagate WORKER_HEADLESS into the session so any worker windows the
    # coordinator spawns inherit it (used by automation/tests where no human
    # is attached to answer claude's trust dialog or interactive REPL).
    if [ -n "${WORKER_HEADLESS:-}" ]; then
        TMUX_ENV_OPTS+=(-e "WORKER_HEADLESS=$WORKER_HEADLESS")
    fi
    if [ -n "$GEMINI_ENV_SOURCED" ]; then
        echo "Loaded GEMINI_API_KEY from $GEMINI_ENV_SOURCED"
    fi
    tmux new-session -d -s "$SESSION_NAME" "${TMUX_ENV_OPTS[@]}" -n "coordinator"
elif $coordinator_idle; then
    echo "Session $SESSION_NAME exists; coordinator pane is idle (previous agent exited). Sending new prompt to existing window."
else
    echo "Session $SESSION_NAME exists; coordinator is busy (running '$PANE_CMD'). Not interrupting — attaching."
fi

# Only build + send a launch command when we have an idle pane to send into.
# (Skipped when an agent is already running in the existing session.)
if ! $session_existed || $coordinator_idle; then
    # We pass the prompt via a temporary file to handle multiline strings safely
    TMP_PROMPT=$(mktemp)
    echo "$INITIAL_PROMPT" > "$TMP_PROMPT"

    # Construct the base command
    if [ "$COORD_CMD" = "gemini" ]; then
        BASE_CMD="GEMINI_SYSTEM_MD='$SYSTEM_PROMPT_FILE' gemini -m '$COORD_MODEL' --yolo --skip-trust"
    elif [ "$COORD_CMD" = "claude" ]; then
        # Claude Max users authenticate via OAuth stored in ~/.claude/. If
        # ANTHROPIC_API_KEY is set, claude-code prefers it over the OAuth
        # session and silently bills the API account. Strip it so Max is used.
        if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
            echo "WARN: ANTHROPIC_API_KEY is set; stripping it from coordinator env so Claude Max OAuth is used."
            echo "      (Set COORDINATOR_USE_API_KEY=1 to keep it and bill the API account instead.)"
        fi
        if [ "${COORDINATOR_USE_API_KEY:-0}" = "1" ]; then
            ENV_PREFIX=""
        else
            ENV_PREFIX="env -u ANTHROPIC_API_KEY "
        fi
        # --append-system-prompt is claude-code's equivalent of GEMINI_SYSTEM_MD.
        # --dangerously-skip-permissions matches gemini --yolo for autonomous ops.
        BASE_CMD="${ENV_PREFIX}claude --append-system-prompt \"\$(cat '$SYSTEM_PROMPT_FILE')\" --dangerously-skip-permissions"
    else
        BASE_CMD="$COORD_CMD"
    fi

    # Default: -p (headless print mode). Both gemini and claude run the prompt
    # and exit. claude's -p prints tool calls as it works (verbose by default);
    # gemini's -p prints only the final answer (silent during work).
    #
    # COORDINATOR_VERBOSE=1 swaps gemini's -p for -i (--prompt-interactive)
    # so you can attach to the pane and watch tool calls live. Trade-off: the
    # gemini agent stays alive after the prompt completes — exit it manually
    # with /quit or Ctrl-D when satisfied. claude is unaffected since its -p
    # is already verbose.
    if [ "$COORD_CMD" = "gemini" ] && [ "${COORDINATOR_VERBOSE:-0}" = "1" ]; then
        PROMPT_FLAG="-i"
        echo "COORDINATOR_VERBOSE=1: gemini will stay interactive after the prompt; exit with /quit."
    else
        PROMPT_FLAG="-p"
    fi

    # Append a trailing call to coordinator-error-tail.sh for the gemini path.
    # gemini-cli truncates server-side errors (e.g. INVALID_ARGUMENT on
    # gemini-3-flash-preview) to "Operation cancelled" in the pane while
    # writing the full payload to /tmp/gemini-*-error-*.json. The tail script
    # surfaces the actual message so users don't have to dig in /tmp.
    # No-op for claude — its -p mode prints tool calls and errors directly.
    if [ "$COORD_CMD" = "gemini" ]; then
        ERR_TAIL='; /opt/work/sysadmin/llm-dev-sandbox/scripts/coordinator-error-tail.sh'
    else
        ERR_TAIL=''
    fi

    tmux send-keys -t "$SESSION_NAME:coordinator" "$BASE_CMD $PROMPT_FLAG \"\$(cat '$TMP_PROMPT')\"; rm '$TMP_PROMPT'$ERR_TAIL" C-m
fi

# Attach or switch to the session
if [ "${NON_INTERACTIVE:-0}" != "1" ]; then
    echo "Connecting to Coordinator..."
    if $IN_TMUX; then
        # If we are already in tmux, switch the client to the new session
        tmux switch-client -t "$SESSION_NAME"
    else
        # Otherwise, attach normally
        tmux attach -t "$SESSION_NAME"
    fi
else
    echo "NON_INTERACTIVE is set. Session $SESSION_NAME created but not attaching."
fi