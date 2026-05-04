#!/usr/bin/env bash
#
# test-shape-orchestration.sh — Non-LLM shape tests for the 3 orchestration
# helpers that aren't covered elsewhere:
#
#   - provision-worker.sh    (creates worktree, queue, brief, tmux window)
#   - coordinator-watch.sh   (wakes coordinator on done/*.json events)
#   - sandbox-worktrees.sh   (lists worktrees; sanity-checks args)
#
# Stubs `gh` and `tmux` via PATH override so tests don't require GitHub
# auth or a live tmux server. Coordinator-watch runs in DRY_RUN=1 + ONCE=1
# so it doesn't actually invoke llm-start.sh.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISION="$SCRIPT_DIR/../scripts/provision-worker.sh"
WATCH="$SCRIPT_DIR/../scripts/coordinator-watch.sh"
LIST="$SCRIPT_DIR/../scripts/sandbox-worktrees.sh"
for s in "$PROVISION" "$WATCH" "$LIST"; do
    [ -x "$s" ] || red "not executable: $s"
done

TEST_DIR=$(mktemp -d -t shape-orch-XXXXXX)
cleanup() {
    [ -n "${WATCH_PID:-}" ] && kill "$WATCH_PID" 2>/dev/null || true
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

# ────────────────────────── Stub gh + tmux on PATH ──────────────────────────

mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Stub: only handles `gh issue view <N>` — emits a fake body.
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
    echo "FAKE-GH issue #${3:-?}: synthetic body for shape test"
    exit 0
fi
echo "stub-gh: unhandled args: $*" >&2
exit 1
EOF
cat > "$TEST_DIR/bin/tmux" <<EOF
#!/usr/bin/env bash
# Stub: provision-worker.sh uses has-session + list-windows + new-window.
# Pretend the session always exists, no windows yet, log new-window calls.
TMUX_LOG="$TEST_DIR/tmux.log"
case "\${1:-}" in
    has-session)   exit 0 ;;
    list-windows)  exit 0 ;;
    new-window)    echo "\$*" >> "\$TMUX_LOG" ;;
    *)             echo "stub-tmux: ignored: \$*" >> "\$TMUX_LOG" ;;
esac
exit 0
EOF
chmod +x "$TEST_DIR/bin/gh" "$TEST_DIR/bin/tmux"
export PATH="$TEST_DIR/bin:$PATH"

# ──────────────────────── Fixture: repo with worktrees ────────────────────────

heading "Setup: fixture git repo"
cd "$TEST_DIR"
mkdir myproject && cd myproject
git init -q -b master
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "initial"
PROJECT_DIR="$TEST_DIR/myproject"
green "fixture ready at $PROJECT_DIR"

# ────────────────────────── provision-worker.sh ──────────────────────────

heading "Test 1: provision-worker.sh creates worktree + branch + brief"
cd "$PROJECT_DIR"
"$PROVISION" 99 > "$TEST_DIR/prov-1.log" 2>&1 || red "provision-worker exit non-zero: $(cat $TEST_DIR/prov-1.log)"
WT="$TEST_DIR/wt-issue-99"
[ -d "$WT" ] || red "worktree not created at $WT"
git -C "$PROJECT_DIR" show-ref --verify --quiet refs/heads/fix/issue-99 \
    || red "branch fix/issue-99 not created"
[ -d "$WT/.swarm/tasks/inbox" ] || red "queue inbox dir not created"
brief=$(ls "$WT"/.swarm/tasks/inbox/*.md | head -1)
[ -n "$brief" ] || red "no brief file in inbox"
grep -q "FAKE-GH issue #99" "$brief" || red "stub gh body not embedded in brief"
grep -qE 'new-window .* iss-99' "$TEST_DIR/tmux.log" \
    || red "expected tmux new-window for iss-99; got: $(cat $TEST_DIR/tmux.log)"
green "worktree, branch, queue, brief (with gh body), tmux new-window all created"

heading "Test 2: provision-worker.sh embeds .swarm-policy.md when present"
cd "$PROJECT_DIR"
echo "RULE: only touch src/" > .swarm-policy.md
git rm -q --cached . 2>/dev/null || true   # keep policy untracked, doesn't matter
"$PROVISION" 100 > "$TEST_DIR/prov-2.log" 2>&1 || red "provision-worker #100 exit non-zero"
WT100="$TEST_DIR/wt-issue-100"
brief100=$(ls "$WT100"/.swarm/tasks/inbox/*.md | head -1)
grep -q "Project Guardrails (MUST OBEY)" "$brief100" \
    || red "policy header missing from brief"
grep -q "RULE: only touch src/" "$brief100" \
    || red "policy body missing from brief"
green "embeds .swarm-policy.md under 'Project Guardrails' heading"

heading "Test 3: provision-worker.sh idempotent re-run reuses worktree"
cd "$PROJECT_DIR"
# TASK_ID has 1-second resolution — sleep so the second brief gets a distinct ID
sleep 1.1
"$PROVISION" 99 > "$TEST_DIR/prov-3.log" 2>&1 || red "provision-worker re-run exit non-zero"
grep -q "worktree already exists — reusing" "$TEST_DIR/prov-3.log" \
    || red "expected 'worktree already exists' message"
# A second brief should now exist for issue 99
count=$(ls "$WT"/.swarm/tasks/inbox/*.md | wc -l)
[ "$count" -ge 2 ] || red "expected ≥2 briefs in inbox after re-run, got $count"
green "re-run reuses worktree, queues a follow-up brief"

# ────────────────────────── coordinator-watch.sh ──────────────────────────

heading "Test 4: coordinator-watch.sh detects new outcome JSON (DRY_RUN, ONCE)"
# coordinator-watch.sh's find scans only under the given project dir.
# Stage the queue dirs INSIDE PROJECT_DIR so the watch can detect them.
mkdir -p "$PROJECT_DIR/.swarm/tasks/done"

# Use a fake llm-start that we'll never actually invoke (DRY_RUN=1)
FAKE_LLM_START="$TEST_DIR/bin/fake-llm-start.sh"
cat > "$FAKE_LLM_START" <<'EOF'
#!/usr/bin/env bash
echo "FAKE-LLM-START invoked: $*"
EOF
chmod +x "$FAKE_LLM_START"

# Start watch in background. Polling backend is fine — gives us deterministic
# semantics, doesn't depend on inotify-tools.
cd "$PROJECT_DIR"
DRY_RUN=1 ONCE=1 POLL_SECS=1 LLM_START="$FAKE_LLM_START" \
    "$WATCH" "$PROJECT_DIR" > "$TEST_DIR/watch.log" 2>&1 &
WATCH_PID=$!

# Give the watch time to baseline existing files
sleep 1.5

# Drop a NEW outcome JSON — should trigger wake
echo '{"task_id":"t1","outcome":"ok"}' > "$PROJECT_DIR/.swarm/tasks/done/t1.ok.json"

# Wait up to 10s for ONCE=1 watch to exit (it should after first wake)
for ((i=0; i<20; i++)); do
    if ! kill -0 "$WATCH_PID" 2>/dev/null; then break; fi
    sleep 0.5
done
wait "$WATCH_PID" 2>/dev/null || true
unset WATCH_PID

grep -q '\[DRY\] would:' "$TEST_DIR/watch.log" \
    || red "expected dry-run log line; full log: $(cat $TEST_DIR/watch.log)"
grep -q "ONCE=1 — exiting after first wake" "$TEST_DIR/watch.log" \
    || red "expected ONCE exit message"
green "polling backend detected new .ok.json, would-wake logged, ONCE=1 exited"

heading "Test 5: coordinator-watch.sh rejects missing project dir"
# realpath bails first under set -e, so we just check non-zero exit + a
# message on stderr (either realpath's or the script's own ERROR).
if "$WATCH" /no/such/dir > "$TEST_DIR/watch-err.log" 2>&1; then
    red "should have failed for missing project dir"
fi
[ -s "$TEST_DIR/watch-err.log" ] || red "expected error output on missing dir"
green "exits non-zero on missing project dir"

# ────────────────────────── sandbox-worktrees.sh ──────────────────────────

heading "Test 6: sandbox-worktrees.sh lists worktrees of a multi-worktree repo"
# We already have 2 extra worktrees (wt-issue-99 and wt-issue-100) plus the
# main repo, so listing should find 3.
cd "$PROJECT_DIR"
out=$(env -u TMUX "$LIST" "$PROJECT_DIR" 2>&1) || red "list mode exit non-zero: $out"
grep -q "Found 3 worktree(s)" <<< "$out" || red "expected 3 worktrees; got: $out"
grep -q "myproject" <<< "$out" || red "expected main worktree 'myproject' listed"
grep -q "wt-issue-99" <<< "$out" || red "expected 'wt-issue-99' listed"
green "lists 3 worktrees (main + 2 wt-issue)"

heading "Test 7: sandbox-worktrees.sh rejects non-git directory"
if env -u TMUX "$LIST" /tmp > "$TEST_DIR/list-err.log" 2>&1; then
    red "should have failed for non-git dir"
fi
grep -q "not a git repository" "$TEST_DIR/list-err.log" \
    || red "expected 'not a git repository' error"
green "exits non-zero with 'not a git repository' error"

heading "Test 8: sandbox-worktrees.sh -t outside tmux session is rejected"
if env -u TMUX "$LIST" -t "$PROJECT_DIR" > "$TEST_DIR/list-err.log" 2>&1; then
    red "should have failed for -t without TMUX env"
fi
grep -q "not inside a tmux session" "$TEST_DIR/list-err.log" \
    || red "expected 'not inside a tmux session' error"
green "exits non-zero with 'not inside a tmux session' error"

# ────────────────────────── Done ──────────────────────────

heading "All shape-orchestration tests passed"
echo "  provision-worker.sh: worktree+branch+brief, policy embedding, idempotent re-run"
echo "  coordinator-watch.sh: polling backend detects new .ok.json, error on missing dir"
echo "  sandbox-worktrees.sh: list mode, non-git error, -t-without-TMUX error"
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
