#!/usr/bin/env bash
#
# coordinator-error-tail.sh — surface gemini-cli API errors in the pane.
#
# gemini-cli truncates server-side errors to "Operation cancelled.[ERROR]
# Operation cancelled." and writes the full payload to /tmp/gemini-*-error-*.json.
# This script tails the most recent such file (only if written in the last
# minute, to avoid stale-error confusion) so the real cause is visible without
# leaving tmux.
#
# Called by llm-start.sh immediately after the gemini invocation in the pane.
# Always exits 0 — we never want a missing error log to mask the agent's
# real result.

set +e

LATEST=$(find /tmp -maxdepth 1 -name 'gemini-*-error*.json' -mmin -1 2>/dev/null | sort | tail -1)
[ -z "$LATEST" ] && exit 0

echo
echo "=== Recent gemini error log surfaced ==="
echo "    file: $LATEST"
if command -v jq >/dev/null 2>&1; then
    # gemini error logs nest the API message at .error.message (sometimes
    # double-encoded JSON inside a JSON string). Try both layers.
    INNER=$(jq -r '.error.message' "$LATEST" 2>/dev/null)
    if [ -n "$INNER" ] && [ "$INNER" != "null" ]; then
        # Try to peel a nested JSON message; fall back to the outer string.
        echo "$INNER" | jq -r '.error.message' 2>/dev/null || echo "$INNER"
    else
        head -100 "$LATEST"
    fi
else
    head -100 "$LATEST"
fi
echo "============================================"
exit 0
