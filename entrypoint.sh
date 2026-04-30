#!/bin/bash
# Register the host's docker group GID so group-name lookups don't warn.
# DOCKER_GID is injected by sandbox.sh when the socket is present.
if [ -n "${DOCKER_GID:-}" ] && ! getent group "$DOCKER_GID" &>/dev/null; then
    sudo groupadd -f -g "$DOCKER_GID" docker 2>/dev/null || true
fi
exec "$@"
