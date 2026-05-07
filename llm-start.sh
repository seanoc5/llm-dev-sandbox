#!/usr/bin/env bash
#
# llm-start.sh - Bootstrap the multi-agent tmux session
#
# This script creates a dedicated tmux session for the current project,
# spawns the coordinator agent (claude by default; gemini if
# COORDINATOR_CMD=gemini) in the first window, and issues its initial
# startup command.
#
# Optional flags (env vars):
#   COORDINATOR_CMD={claude,gemini}   Default: claude
#   COORDINATOR_MODEL=<id>            Per-coordinator default; see below
#   COORDINATOR_VERBOSE=1             Stay interactive in coordinator pane
#   WATCH=1                           Spawn coordinator-watch.sh in a 2nd
#                                     tmux window (carries POST_OUTCOMES,
#                                     OUTCOME_HOOK, DEBOUNCE_SECS, etc.
#                                     from caller env)
#   STATUS=1                          Spawn gh-status-bar.sh in a 'status'
#                                     tmux window — updates the session's
#                                     status-right with live open-issue/
#                                     open-PR/closed-today counts. Carries
#                                     STATUS_INTERVAL, STATUS_LENGTH,
#                                     STATUS_FORMAT, GH_TIMEOUT.
#   NON_INTERACTIVE=1                 Don't auto-attach to the session
set -euo pipefail

# Configuration
# Self-locate so the sandbox tree works from any clone path (not tied to
# /opt/work/sysadmin/...). LLM_SANDBOX_DIR overrides if you want to point at
# a different install while running this script from elsewhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_SANDBOX_DIR="${LLM_SANDBOX_DIR:-$SCRIPT_DIR}"

SESSION_NAME="llm-$(basename "$PWD")"
SYSTEM_PROMPT_FILE="$LLM_SANDBOX_DIR/prompts/coordinator.md"

# --- Help / usage ----------------------------------------------------------

usage() {
    cat <<EOF
llm-start.sh — Bootstrap a multi-agent tmux coordinator session

USAGE
    llm-start.sh [FLAGS] [PROMPT]

ARGUMENTS
    PROMPT          Initial prompt for the coordinator
                    (default: "Execute the Initial Startup Checklist.")

FLAGS
    -h, --help                       Show this help and exit
    -w, --watch                      Spawn coordinator-watch.sh   (= WATCH=1)
    -y, --yolo                       Opinionated automation bundle (see below)
        --status                     Spawn gh-status-bar window   (= STATUS=1)
        --max-workers N              Concurrent worker tmux windows
        --max-windows N              Total session window cap (HARD)
        --target-available N         AVAILABLE backlog target
        --include-others             Claim others' tickets        (= INCLUDE_ASSIGNED_TO_OTHERS=1)
        --owner-labels L1,L2         Comma-sep labels meaning "human-owned"

YOLO BUNDLE
    --yolo sets, only when not already set: WATCH=1 STATUS=1 MAX_WORKERS=5
    INCLUDE_ASSIGNED_TO_OTHERS=1 DEBOUNCE_SECS=15.
    Explicit flags and shell env still win, so 'MAX_WORKERS=8 ./llm-start.sh
    --yolo' gives 8 workers. MAX_TMUX_WINDOWS stays at 10 — the runaway
    brake is never disabled by yolo.

ENV VARS  (precedence: flag > shell env > <project>/.swarm/.env > <sandbox>/.env.example)

  Coordinator
    COORDINATOR_CMD              claude    claude | gemini
    COORDINATOR_MODEL            (varies)  per-coordinator default
    COORDINATOR_VERBOSE          0         gemini -i instead of -p
    COORDINATOR_USE_API_KEY      0         keep ANTHROPIC_API_KEY (bills API)

  Caps & filters  [also loadable from <project>/.swarm/.env]
    MAX_WORKERS                  2         concurrent worker tmux windows
    MAX_TMUX_WINDOWS             10        total session window cap (HARD)
    TARGET_AVAILABLE             5         AVAILABLE backlog target
    OWNER_LABELS                 (empty)   comma-sep labels = "human-owned"
    INCLUDE_ASSIGNED_TO_OTHERS   0         1 = claim others' tickets

  Watcher (when WATCH=1)
    WATCH                        0         spawn coordinator-watch.sh
    DEBOUNCE_SECS                30        wake coalescing window
    POLL_SECS                    2         poll-mode latency
    POST_OUTCOMES                0         run sweep on each outcome
    OUTCOME_HOOK                 (none)    path to per-outcome poster script

  Misc
    STATUS                       0         spawn gh-status-bar window
    NON_INTERACTIVE              0         don't auto-attach (for tests)

EXAMPLES
    ./llm-start.sh                              # one-shot triage, defaults
    ./llm-start.sh -w                           # one-shot + auto top-up
    ./llm-start.sh --yolo                       # unattended sprint mode
    ./llm-start.sh --max-workers 8 -w           # 8 workers, watcher on
    MAX_WORKERS=8 ./llm-start.sh --yolo         # 8 (env wins over yolo's 5)
    ./llm-start.sh "claim Radesh's tickets"     # free-text override

DOCS
    README:    $LLM_SANDBOX_DIR/README.md
    Overview:  $LLM_SANDBOX_DIR/docs/llm-dev-sandbox-overview.md
EOF
}

# --- Flag parsing ----------------------------------------------------------
# Flags export immediately, beating shell env (so --max-workers 10 wins over
# MAX_WORKERS=8). The env loader (sourced after this loop) only sets unset
# vars, giving the standard precedence: flag > shell env > project .env >
# sandbox .env.example.

require_value() {
    if [ -z "${2:-}" ] || [[ "${2:-}" == -* ]]; then
        echo "ERROR: $1 requires a value" >&2
        exit 1
    fi
}

YOLO=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)              usage; exit 0 ;;
        -w|--watch)             export WATCH=1; shift ;;
        -y|--yolo)              YOLO=1; shift ;;
        --status)               export STATUS=1; shift ;;
        --include-others)       export INCLUDE_ASSIGNED_TO_OTHERS=1; shift ;;
        --max-workers)          require_value "$1" "${2:-}"; export MAX_WORKERS="$2"; shift 2 ;;
        --max-workers=*)        export MAX_WORKERS="${1#*=}"; shift ;;
        --max-windows)          require_value "$1" "${2:-}"; export MAX_TMUX_WINDOWS="$2"; shift 2 ;;
        --max-windows=*)        export MAX_TMUX_WINDOWS="${1#*=}"; shift ;;
        --target-available)     require_value "$1" "${2:-}"; export TARGET_AVAILABLE="$2"; shift 2 ;;
        --target-available=*)   export TARGET_AVAILABLE="${1#*=}"; shift ;;
        --owner-labels)         require_value "$1" "${2:-}"; export OWNER_LABELS="$2"; shift 2 ;;
        --owner-labels=*)       export OWNER_LABELS="${1#*=}"; shift ;;
        --)                     shift; break ;;
        -*)                     echo "ERROR: unknown flag: $1 (try --help)" >&2; exit 1 ;;
        *)                      break ;;   # positional PROMPT starts here
    esac
done

# --yolo bundle: apply opinionated defaults AFTER explicit flags. The
# `:= ` form only sets when unset, so any flag/env value the user already
# supplied wins. MAX_TMUX_WINDOWS deliberately not bumped — runaway brake
# is never relaxed by yolo.
if [ "$YOLO" = "1" ]; then
    : "${WATCH:=1}";                      export WATCH
    : "${STATUS:=1}";                     export STATUS
    : "${MAX_WORKERS:=5}";                export MAX_WORKERS
    : "${INCLUDE_ASSIGNED_TO_OTHERS:=1}"; export INCLUDE_ASSIGNED_TO_OTHERS
    : "${DEBOUNCE_SECS:=15}";             export DEBOUNCE_SECS
fi

INITIAL_PROMPT="${1:-Execute the Initial Startup Checklist.}"

# Load <project>/.swarm/.env then <sandbox>/.env.example. Vars set above by
# flags or yolo (or by the caller's shell env) survive — the loader only
# fills in still-unset vars. Final precedence:
#   flag > shell env > <project>/.swarm/.env > <sandbox>/.env.example
# shellcheck source=scripts/_load-env.sh
. "$LLM_SANDBOX_DIR/scripts/_load-env.sh" "$PWD"

# Allow overriding the coordinator command and model
COORD_CMD="${COORDINATOR_CMD:-claude}"
# Default model depends on which coordinator is running:
#   claude → claude-opus-4-7[1m] (Opus 4.7 with 1M context — note brackets
#     are part of the literal model id; must be single-quoted at the shell
#     to suppress glob expansion).
#   gemini → gemini-2.5-flash (stable). gemini-3-flash-preview returns
#     INVALID_ARGUMENT on multi-step tool sequences (which is the
#     coordinator's whole job), so it's not a viable default.
# Override either via COORDINATOR_MODEL=<id>.
case "$COORD_CMD" in
    claude) COORD_MODEL_DEFAULT='claude-opus-4-7[1m]' ;;
    gemini) COORD_MODEL_DEFAULT='gemini-2.5-flash' ;;
    *)      COORD_MODEL_DEFAULT='' ;;
esac
COORD_MODEL="${COORDINATOR_MODEL:-$COORD_MODEL_DEFAULT}"

# Auto-discover GEMINI_API_KEY when running gemini coordinator. Gemini CLI only
# auto-loads .env from CWD/walks up to $HOME and ~/.gemini/.env — it never
# finds keys stored outside those paths. So we walk a configurable list and
# source the first match. tmux new-session -e then propagates it into the
# coordinator pane.
#
# Default search list works on the original minti9 layout. Append to it via
# LLM_ENV_FILES (colon-separated, like $PATH) for additional locations
# without losing the defaults.
GEMINI_ENV_SOURCED=""
if [ "$COORD_CMD" = "gemini" ] && [ -z "${GEMINI_API_KEY:-}" ]; then
    _env_candidates=(
        "$PWD/.env"
        "$HOME/.gemini/.env"
        "$LLM_SANDBOX_DIR/.env"
        "/opt/work/sysadmin/.env"
    )
    if [ -n "${LLM_ENV_FILES:-}" ]; then
        IFS=':' read -ra _extra_envs <<< "$LLM_ENV_FILES"
        _env_candidates+=("${_extra_envs[@]}")
    fi
    for _candidate in "${_env_candidates[@]}"; do
        if [ -f "$_candidate" ] && grep -q '^GEMINI_API_KEY=' "$_candidate" 2>/dev/null; then
            set -a
            # shellcheck source=/dev/null
            . "$_candidate"
            set +a
            if [ -n "${GEMINI_API_KEY:-}" ]; then
                GEMINI_ENV_SOURCED="$_candidate"
                break
            fi
        fi
    done
    if [ -z "${GEMINI_API_KEY:-}" ]; then
        echo "WARN: GEMINI_API_KEY not in env and not found in any of:" >&2
        printf '      %s\n' "${_env_candidates[@]}" >&2
        echo "      (extend the search list via LLM_ENV_FILES=path1:path2:...)" >&2
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
    # Propagate sandbox config into the session so the coordinator LLM and
    # any provision-worker.sh invocations within the session see the same
    # caps and filters loaded from .env.example / .swarm/.env above.
    for _v in MAX_WORKERS MAX_TMUX_WINDOWS TARGET_AVAILABLE OWNER_LABELS \
              INCLUDE_ASSIGNED_TO_OTHERS DEBOUNCE_SECS POLL_SECS \
              LLM_SANDBOX_DIR; do
        _val="${!_v:-}"
        [ -n "$_val" ] && TMUX_ENV_OPTS+=(-e "$_v=$_val")
    done
    unset _v _val
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

    # Render the system prompt with {{LLM_SANDBOX_DIR}} substituted, so the
    # coordinator's instructions reference the actual install path rather
    # than a hardcoded one. The rendered file is consumed below by
    # GEMINI_SYSTEM_MD / --append-system-prompt; we let it leak into /tmp
    # since it's tiny, deterministic, and the rendered prompt is harmless.
    RENDERED_PROMPT_FILE=$(mktemp -t coordinator-prompt-XXXXXX.md)
    sed "s|{{LLM_SANDBOX_DIR}}|$LLM_SANDBOX_DIR|g" "$SYSTEM_PROMPT_FILE" > "$RENDERED_PROMPT_FILE"

    # Construct the base command
    if [ "$COORD_CMD" = "gemini" ]; then
        BASE_CMD="GEMINI_SYSTEM_MD='$RENDERED_PROMPT_FILE' gemini -m '$COORD_MODEL' --yolo --skip-trust"
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
        # --model only when COORD_MODEL is set. The single quotes around
        # $COORD_MODEL are literal characters embedded in BASE_CMD — needed
        # so the default 'claude-opus-4-7[1m]' (which contains bash glob
        # chars [ and ]) survives shell parsing when BASE_CMD is executed.
        # shellcheck disable=SC2016  # $COORD_MODEL is in double-quoted context, so it does expand
        BASE_CMD="${ENV_PREFIX}claude ${COORD_MODEL:+--model '$COORD_MODEL'} --append-system-prompt \"\$(cat '$RENDERED_PROMPT_FILE')\" --dangerously-skip-permissions"
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
    if [ "$COORD_CMD" = "gemini" ] && [ "${COORDINATOR_VERBOSE:-1}" = "1" ]; then
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
        ERR_TAIL="; $LLM_SANDBOX_DIR/scripts/coordinator-error-tail.sh"
    else
        ERR_TAIL=''
    fi

    # Wrap BASE_CMD with pre-banner (project/model/prompt-summary) and
    # post-footer (exit rc + duration) so the pane shows lifecycle status
    # instead of going silent while claude reasons. Without these you can't
    # tell "running" from "hung" or "exited cleanly". Script-time vars
    # expand here; runtime $vars and $(...) are escaped to defer to the
    # pane's shell.
    LAUNCH_BANNER="echo \"=== coordinator launching @ \$(date '+%Y-%m-%d %H:%M:%S') ===\"; echo \"project: $PWD\"; echo \"model:   ${COORD_MODEL:-(default)}\"; echo \"prompt:  \$(head -1 '$TMP_PROMPT')\"; echo '---'"
    LAUNCH_FOOTER="_rc=\$?; _t1=\$(date +%s); rm '$TMP_PROMPT'$ERR_TAIL; echo; echo \"=== coordinator exited rc=\$_rc @ \$(date +%H:%M:%S) (duration \$((_t1 - _t0))s) ===\""

    tmux send-keys -t "$SESSION_NAME:coordinator" \
        "$LAUNCH_BANNER; _t0=\$(date +%s); $BASE_CMD $PROMPT_FLAG \"\$(cat '$TMP_PROMPT')\"; $LAUNCH_FOOTER" C-m
fi

# Optionally spawn coordinator-watch.sh in its own tmux window so the
# unattended supervisor pattern is one command instead of two terminals.
# WATCH=1 enables; POST_OUTCOMES + OUTCOME_HOOK propagate from caller env
# (so `WATCH=1 POST_OUTCOMES=1 OUTCOME_HOOK=/path ./llm-start.sh` gives
# you coordinator + watcher + audit posting from a single invocation).
# Idempotent: skips if a 'watch' window already exists in the session.
if [ "${WATCH:-1}" = "1" ]; then
    if tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep -qx 'watch'; then
        echo "tmux window '$SESSION_NAME:watch' already exists — skipping watch spawn"
    else
        WATCH_SCRIPT="$LLM_SANDBOX_DIR/scripts/coordinator-watch.sh"
        # printf %q makes every value safe for re-parsing in the new shell,
        # which matters for OUTCOME_HOOK paths and prompts that may contain
        # spaces or quotes.
        WATCH_CMD=""
        for _v in POST_OUTCOMES OUTCOME_HOOK DEBOUNCE_SECS WAKE_PROMPT POLL_SECS WORKSPACE SWEEP; do
            _val="${!_v:-}"
            [ -n "$_val" ] && WATCH_CMD+="$_v=$(printf '%q' "$_val") "
        done
        WATCH_CMD+="$WATCH_SCRIPT $(printf '%q' "$PWD")"
        tmux new-window -d -t "$SESSION_NAME" -n watch "$WATCH_CMD"
        echo "Spawned coordinator-watch in tmux window '$SESSION_NAME:watch'"
        if [ "${POST_OUTCOMES:-0}" = "1" ] && [ -z "${OUTCOME_HOOK:-}" ]; then
            echo "  WARN: POST_OUTCOMES=1 but no OUTCOME_HOOK set — sweep will use dry-run stub (no real posts)"
        fi
    fi
fi

# Optionally spawn gh-status-bar.sh in a 'status' window. Updates the tmux
# session's status-right with live open-issue / open-PR / closed-today
# counts so they're visible from every window. Independent of WATCH — the
# status bar polls gh on its own cadence (default 60s) regardless of
# whether worker outcomes are landing.
if [ "${STATUS:-0}" = "1" ]; then
    if tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep -qx 'status'; then
        echo "tmux window '$SESSION_NAME:status' already exists — skipping status spawn"
    else
        STATUS_SCRIPT="$LLM_SANDBOX_DIR/scripts/gh-status-bar.sh"
        STATUS_CMD=""
        for _v in STATUS_INTERVAL STATUS_LENGTH STATUS_FORMAT GH_TIMEOUT; do
            _val="${!_v:-}"
            [ -n "$_val" ] && STATUS_CMD+="$_v=$(printf '%q' "$_val") "
        done
        STATUS_CMD+="$STATUS_SCRIPT $(printf '%q' "$SESSION_NAME") $(printf '%q' "$PWD")"
        tmux new-window -d -t "$SESSION_NAME" -n status "$STATUS_CMD"
        echo "Spawned gh-status-bar in tmux window '$SESSION_NAME:status'"
    fi
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