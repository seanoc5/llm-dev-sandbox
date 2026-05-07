#!/bin/bash
# Register the host's docker group GID so group-name lookups don't warn.
# DOCKER_GID is injected by sandbox.sh when the socket is present.
if [ -n "${DOCKER_GID:-}" ] && ! getent group "$DOCKER_GID" &>/dev/null; then
    sudo groupadd -f -g "$DOCKER_GID" docker 2>/dev/null || true
fi

# Seed ATUIN_SESSION so atuin subcommands (hook, search, history) work in
# non-interactive contexts: claude-code PreToolUse/PostToolUse hooks (which
# run via /bin/sh, never sourcing .bashrc); `bash -c '…'` invocations; and
# `claude` / `gemini` / `listener` agent CMDs that bypass bash entirely.
# atuin's bash init normally exports this; without it the hooks fail with
# "Failed to find $ATUIN_SESSION in the environment".
if command -v atuin >/dev/null 2>&1 && [ -z "${ATUIN_SESSION:-}" ]; then
    export ATUIN_SESSION="$(atuin uuid 2>/dev/null)" || unset ATUIN_SESSION
fi

exec "$@"
