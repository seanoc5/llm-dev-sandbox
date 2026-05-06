#!/usr/bin/env bash
#
# setup.sh — Host-side setup for llm-dev-sandbox.
#
# Currently fixes one known issue: the npm-published @google/gemini-cli
# package is missing its bundled ripgrep binary, but the agent still
# checks for it at runtime and falls back to a slower built-in grep
# while logging "Ripgrep is not available." We symlink the system's
# /usr/bin/rg into the path gemini-cli expects.
#
# Idempotent: safe to re-run after `npm i -g @google/gemini-cli` upgrades.
set -euo pipefail

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

echo "=== llm-dev-sandbox host setup ==="

# --- 1. Locate gemini-cli ---
if ! command -v npm >/dev/null 2>&1; then
    red "npm not found on \$PATH. Install Node.js first."
    exit 1
fi

NPM_GLOBAL_ROOT="$(npm root -g)"
GEMINI_DIR="${NPM_GLOBAL_ROOT}/@google/gemini-cli"
if [ ! -d "$GEMINI_DIR" ]; then
    yellow "@google/gemini-cli not installed globally."
    yellow "  Install with:  npm install -g @google/gemini-cli"
    yellow "Skipping ripgrep symlink."
    exit 0
fi

# --- 2. Locate system ripgrep ---
RG_PATH="$(command -v rg || true)"
if [ -z "$RG_PATH" ]; then
    red "ripgrep ('rg') not found on \$PATH."
    red "  Install with:  sudo apt install ripgrep   (or your platform's equivalent)"
    exit 1
fi

# --- 3. Detect platform/arch (matches gemini-cli's getRipgrepPath naming) ---
PLAT="$(node -e 'process.stdout.write(process.platform)')"
ARCH="$(node -e 'process.stdout.write(process.arch)')"
EXT=""
[ "$PLAT" = "win32" ] && EXT=".exe"
BIN_NAME="rg-${PLAT}-${ARCH}${EXT}"

# --- 4. Create the symlink ---
VENDOR_DIR="${GEMINI_DIR}/bundle/vendor/ripgrep"
mkdir -p "$VENDOR_DIR"
TARGET="${VENDOR_DIR}/${BIN_NAME}"

if [ -L "$TARGET" ] && [ "$(readlink "$TARGET")" = "$RG_PATH" ]; then
    green "✓ Already linked: $TARGET -> $RG_PATH"
else
    ln -sf "$RG_PATH" "$TARGET"
    green "✓ Linked: $TARGET -> $RG_PATH"
fi

echo

# --- 5. LLM_SANDBOX_DIR export hint ---------------------------------------
# Scripts self-locate via BASH_SOURCE so the runtime path is portable, but
# users who invoke them from arbitrary directories (or via wrapper scripts)
# benefit from having LLM_SANDBOX_DIR exported in their shell rc — that way
# `coordinator.md` template substitution and `.env` search paths use the
# right install regardless of how scripts are reached.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_SANDBOX_DIR="$(dirname "$SCRIPT_DIR")"

# Only print the hint if the user's environment doesn't already match.
if [ "${LLM_SANDBOX_DIR_ENV:-${LLM_SANDBOX_DIR_ENV_VAR:-}}" != "$LLM_SANDBOX_DIR" ]; then
    yellow "Tip: add this to your ~/.bashrc / ~/.zshrc so all callers find this install:"
    echo "    export LLM_SANDBOX_DIR=\"$LLM_SANDBOX_DIR\""
    echo "    export PATH=\"\$LLM_SANDBOX_DIR:\$LLM_SANDBOX_DIR/scripts:\$PATH\""
    echo
fi

# --- 6. Bash completion install hint --------------------------------------
COMPLETION_FILE="$LLM_SANDBOX_DIR/completions/llm-dev-sandbox.bash"
if [ -f "$COMPLETION_FILE" ]; then
    yellow "Tip: enable tab-completion for llm-start.sh / coordinator-watch.sh / provision-worker.sh:"
    echo "    . \"$COMPLETION_FILE\"   # add to ~/.bashrc"
    echo
fi

green "Setup complete."
