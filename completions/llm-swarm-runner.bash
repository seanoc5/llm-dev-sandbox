# llm-swarm-runner bash completion
#
# Source from your ~/.bashrc:
#     . /path/to/llm-swarm-runner/completions/llm-swarm-runner.bash
#
# Or copy into the XDG bash-completion dir for lazy-load:
#     mkdir -p ~/.local/share/bash-completion/completions
#     cp llm-swarm-runner.bash ~/.local/share/bash-completion/completions/llm-start.sh
#
# Provides flag completion for the three user-facing entry points.
# No dependency on the bash-completion package — uses only POSIX-y compgen.

# --- llm-start.sh ----------------------------------------------------------

_llm_start_completion() {
    local cur prev flags
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    flags="-h --help -w --watch -y --yolo --status --include-others \
           --max-workers --max-windows --target-available --owner-labels"

    # Cursor sits on the VALUE for a flag-that-takes-value (--flag VALUE form)
    case "$prev" in
        --max-workers|--max-windows|--target-available)
            # Numeric — suggest a few sane values, user can override freely
            COMPREPLY=( $(compgen -W "1 2 3 5 8 10" -- "$cur") )
            return 0
            ;;
        --owner-labels)
            # Free-text comma-list; no useful suggestion without gh round-trip
            COMPREPLY=()
            return 0
            ;;
    esac

    # --flag=VALUE form — cursor inside the value, no suggestion
    case "$cur" in
        --*=*) COMPREPLY=(); return 0 ;;
    esac

    # Otherwise, complete a flag if the user typed a leading dash
    if [[ "$cur" == -* ]]; then
        # shellcheck disable=SC2207
        COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
        return 0
    fi

    # Positional PROMPT is free-text — no completion
    COMPREPLY=()
}
complete -F _llm_start_completion llm-start.sh
complete -F _llm_start_completion llm-start    # in case the user dropped the .sh

# --- coordinator-watch.sh --------------------------------------------------

_coordinator_watch_completion() {
    local cur
    cur="${COMP_WORDS[COMP_CWORD]}"

    if [[ "$cur" == -* ]]; then
        # shellcheck disable=SC2207
        COMPREPLY=( $(compgen -W "-h --help" -- "$cur") )
    else
        # Positional [project-dir] — directory completion
        # shellcheck disable=SC2207
        COMPREPLY=( $(compgen -d -- "$cur") )
    fi
}
complete -F _coordinator_watch_completion coordinator-watch.sh
complete -F _coordinator_watch_completion coordinator-watch

# --- provision-worker.sh ---------------------------------------------------

_provision_worker_completion() {
    local cur
    cur="${COMP_WORDS[COMP_CWORD]}"

    if [[ "$cur" == -* ]]; then
        # shellcheck disable=SC2207
        COMPREPLY=( $(compgen -W "-h --help" -- "$cur") )
    elif [[ "$COMP_CWORD" -eq 1 ]]; then
        # Position 1 = issue number. Could query `gh issue list` here, but
        # that hits the network on every tab press. Skip; leave to the user.
        COMPREPLY=()
    else
        # Position 2 = [project-dir]
        # shellcheck disable=SC2207
        COMPREPLY=( $(compgen -d -- "$cur") )
    fi
}
complete -F _provision_worker_completion provision-worker.sh
complete -F _provision_worker_completion provision-worker

# --- kill-finished-workers.sh ---------------------------------------------

_kill_finished_workers_completion() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    case "$prev" in
        -s|--session)
            # Suggest existing tmux sessions whose names start with "llm-"
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "$(tmux list-sessions -F '#S' 2>/dev/null | grep '^llm-')" -- "$cur") )
            return 0
            ;;
        -i|--idle-min)
            # Common minute thresholds; user can override freely
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "1 2 5 10 15 30 60" -- "$cur") )
            return 0
            ;;
    esac

    case "$cur" in
        --session=*|--idle-min=*) COMPREPLY=(); return 0 ;;
    esac

    if [[ "$cur" == -* ]]; then
        # shellcheck disable=SC2207
        COMPREPLY=( $(compgen -W "-h --help -a --all -w --with-worktree -n --dry-run -y --yes -s --session -i --idle-min --no-pr-check" -- "$cur") )
        return 0
    fi
    COMPREPLY=()
}
complete -F _kill_finished_workers_completion kill-finished-workers.sh
complete -F _kill_finished_workers_completion kill-finished-workers
