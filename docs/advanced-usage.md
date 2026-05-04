# Advanced Usage & Configuration

This document covers advanced workflows, custom mounts, and manual Git worktree setups.

## Contents

- [Git Worktrees](#git-worktrees)
  - [Manual Multi-worktree tmux setup](#manual-multi-worktree-tmux-setup)
  - [Creating worktrees manually](#creating-worktrees-manually)
- [Custom Configuration](#custom-configuration)
  - [Per-project Environment (.sandbox-env)](#per-project-environment-sandbox-env)
  - [Extra Mounts](#extra-mounts)
- [Docker Integrations](#docker-integrations)
  - [Testcontainers / Docker CLI](#testcontainers--docker-cli)
  - [Rebuilding the Image](#rebuilding-the-image)
- [Triage Workflow](#triage-workflow)
  - [The triage cycle](#the-triage-cycle)
  - [Read-only triage prompt](#read-only-triage-prompt)
  - [Acting on each verdict](#acting-on-each-verdict)
  - [Reviving listeners after a tmux session is killed](#reviving-listeners-after-a-tmux-session-is-killed)

## Git Worktrees

`sandbox.sh` automatically detects git worktrees. When the project directory is a worktree (its `.git` is a file pointing to the main repo), the script mounts the main repo's `.git/` directory into the container so all git operations work normally.

### Manual Multi-worktree tmux setup

While `llm-start.sh` handles orchestration autonomously, you can manually use `sandbox-worktrees.sh` to list worktrees and optionally create tmux windows and/or launch sandboxes:

```bash
# List all worktrees and their branches
./scripts/sandbox-worktrees.sh /opt/work/myproject

# Launch Claude sandbox in the current shell for this worktree
./scripts/sandbox-worktrees.sh -a claude

# Create tmux windows starting at 7 — one per worktree
./scripts/sandbox-worktrees.sh -t /opt/work/myproject

# Create tmux windows AND launch Claude in each
./scripts/sandbox-worktrees.sh -t -a claude /opt/work/myproject

# Start at window 3 (implies -t)
./scripts/sandbox-worktrees.sh -s 3 -a gemini /opt/work/myproject
```

The `-a` flag behaves differently depending on whether `-t` is present:
- **`-a` alone:** launches the sandbox in the current shell via `exec` (replaces the shell process).
- **`-t -a`:** creates tmux windows and launches a sandbox in each.

This pairs well with projects that use docker compose with per-worktree port offsets (via `.env` files), letting you run fully isolated stacks side by side. A typical setup:

```
Window 7:  fand-api       (main worktree, master)     → ports 35432, 18081, 18082
Window 8:  fand-api-wt1   (feature/new-batch-job)     → ports 35433, 18084, 18083
Window 9:  fand-api-wt2   (fix/dashboard-bug)         → ports 35434, 18086, 18085
Window 10: fand-api-wt3   (spike/experiment)           → ports 35435, 18088, 18087
```

### Creating worktrees manually

```bash
# From the main repo — create worktrees alongside it
cd /opt/work/myproject
git worktree add ../myproject-wt1 master
git worktree add ../myproject-wt2 --detach HEAD

# List all worktrees
git worktree list

# Clean up when done
git worktree remove ../myproject-wt2
```

## Custom Configuration

### Per-project Environment (`.sandbox-env`)

Create a `.sandbox-env` file in your project directory to pre-set credentials and service URLs. `sandbox.sh` passes it to the container via `--env-file` when present.

```bash
# /opt/work/myproject/.sandbox-env  — gitignore this file
PGHOST=localhost
PGPORT=5432
PGDATABASE=mydb
PGUSER=myuser
PGPASSWORD=mypassword
APP_URL=http://localhost:8080
```

Add `.sandbox-env` to your project's `.gitignore` to avoid committing credentials.

### Extra Mounts

Pass additional mounts via `EXTRA_MOUNTS` (comma-separated). Two formats are supported:

```bash
# Same-path mirror — host path appears at the same path inside the container
EXTRA_MOUNTS="/opt/data/myfiles/:ro" ./sandbox.sh /path/to/project

# Explicit host:container mapping
EXTRA_MOUNTS="/opt/data:/mnt/data:ro" ./sandbox.sh /path/to/project

# Multiple mounts
EXTRA_MOUNTS="/opt/data:ro,/opt/models:/models:ro" ./sandbox.sh /path/to/project
```

## Docker Integrations

### Testcontainers / Docker CLI

The host Docker socket (`/var/run/docker.sock`) is mounted automatically when present. `entrypoint.sh` adds the sandbox user to the docker group at startup (using `DOCKER_GID`) to silence permission errors. `TESTCONTAINERS_HOST_OVERRIDE=localhost` is set automatically so Testcontainers resolves mapped ports correctly with `--network host`.

### Rebuilding the Image

```bash
# After Dockerfile changes
docker build -t llm-sandbox:latest .

# Force a full rebuild (no cache)
docker build --no-cache -t llm-sandbox:latest .
```

## Triage Workflow

A pattern that recurs whenever a swarm of workers has been running for a while: their tmux session dies (reboot, accidental kill, ssh hang-up), but their worktrees + branches + queue state survive on disk. You come back to N abandoned worktrees and need to decide, per worktree, whether to merge / abandon / continue.

The four-tool kit is built for exactly this:

| Helper | Used for |
|---|---|
| `llm-start.sh "<prompt>"` | Wake the coordinator with a custom prompt |
| `provision-worker.sh <issue>` | Create a fresh worktree + queue + listener |
| `requeue.sh <issue\|wt-path> <brief>` | Drop a follow-up brief into an existing worker's queue |
| `kill-worktree.sh <issue>` | Remove worktree, branch, and tmux window |

### The triage cycle

1. **Wake the coordinator** with a read-only triage prompt → get a markdown table of verdicts.
2. **Sanity-check the verdicts yourself** (30 seconds of `git log` per worktree).
3. **Act on each verdict** using the helper scripts (commands below).
4. **Revive listeners** for any worktrees that need a follow-up worker invocation.

### Read-only triage prompt

Use `COORDINATOR_CMD=claude` for this — claude streams tool calls cleanly to the pane and isn't subject to the `$(...)` block that gemini's `run_shell_command` enforces.

```bash
cd /opt/work/myproject
COORDINATOR_CMD=claude $LLM_SANDBOX_DIR/llm-start.sh "$(cat <<'EOF'
Triage the existing worker worktrees. READ-ONLY — do NOT push, do NOT
open PRs, do NOT merge, do NOT close issues, do NOT remove worktrees,
do NOT provision new workers.

For each ../wt-issue-* worktree relative to this project:

1. git -C <wt> log --oneline master..HEAD          (commits made)
2. git -C <wt> diff --stat master..HEAD            (scope of changes)
3. cat <wt>/.swarm/tasks/done/*.json | tail -n 1   (latest outcome)
4. gh issue view <N>                               (the issue)

Decide one verdict per worktree:

- READY:        work matches issue, looks correct, recommend pushing + PR.
- NEEDS_REVIEW: work was done but you have a concern (scope creep,
                missing tests, conflicts with PRs that landed on master
                while the worker ran). Flag the specific concern.
- PARTIAL:      real attempt that didn't complete. Recommend a
                follow-up brief outlining what's missing.
- ABANDON:      work is wrong / off-target / superseded by a merged PR.
                Recommend deletion (do NOT execute deletion).

Output ONE markdown table:

  issue | branch | commits | files-touched | verdict | one-sentence reasoning

After the table, list any worktrees with NO .swarm/tasks/done/*.json
(older pre-v2 worktrees) — verdict relies on git log + diff alone for those.
EOF
)"
tmux a -t llm-$(basename $PWD)
```

### Acting on each verdict

#### READY → push + open PR

If you trust the verdict, this is one push + one `gh pr create` per worktree:

```bash
WT=/opt/work/myproject/../wt-issue-N
BRANCH=$(git -C "$WT" branch --show-current)
git -C "$WT" push -u origin "$BRANCH"
gh -R <owner>/<repo> pr create \
    --base master --head "$BRANCH" \
    --title "[swarm] <short summary> (closes #N)" \
    --body-file "$WT/.swarm/tasks/done/<id>.md"   # the original brief is fine as PR body
```

If the coordinator's READY list is short, do them by hand. If it's long, you can ask the coordinator to do this in a follow-up wake — just give it the explicit "for each READY in the table, push and PR" prompt (the *permissive* triage variant).

#### NEEDS_REVIEW → surgical re-do brief

The worker's branch contains a mix of valuable new work AND stale changes that conflict with master (because master moved while the worker ran). Drop a brief telling a fresh worker to reset and re-apply only the salvageable parts:

```bash
cat <<'BRIEF' | $LLM_SANDBOX_DIR/scripts/requeue.sh N -
## Surgical re-do for issue #N

Your earlier work added <X valuable thing> AND a rewrite of <Y> that
has since been merged via PR #M.

Reset this branch to current origin/master and keep ONLY the X work.
DO NOT touch Y.

Steps:
1. git fetch origin
2. git reset --hard origin/master
3. Re-apply only the X work.
4. Run the test suite to verify against current master.
5. Push and PR titled "[swarm] <new title>".

If X doesn't compile/pass against current master (APIs changed, etc.),
STOP and report what broke — don't try to "fix" surrounding code.
BRIEF
```

`requeue.sh` also prints a hint if no listener tmux window is currently polling — see [Reviving listeners](#reviving-listeners-after-a-tmux-session-is-killed) below.

#### PARTIAL → follow-up brief listing what's missing

Same shape as NEEDS_REVIEW, but the brief just enumerates the remaining scope:

```bash
cat <<'BRIEF' | $LLM_SANDBOX_DIR/scripts/requeue.sh N -
## Follow-up to your prior work on issue #N

You completed <subset>. The issue scope was <full set> — <remainder> remains:

- <item 1>
- <item 2>
- ...

Same conventions as last time. Stop and ask if any item has unusual
setup. When done, push and open a PR titled "[swarm] <full-scope title>".
BRIEF
```

#### ABANDON → clean removal

```bash
# single
$LLM_SANDBOX_DIR/scripts/kill-worktree.sh N

# batch
for issue in <list>; do
    $LLM_SANDBOX_DIR/scripts/kill-worktree.sh "$issue"
done
```

`kill-worktree.sh` prints `<commits ahead, M uncommitted>` before deletion so a worktree with unexpected work doesn't get silently dropped.

### Reviving listeners after a tmux session is killed

When the tmux session dies, worktrees survive but listeners don't. To pick up where you left off:

```bash
cd /opt/work/myproject

# 1. Recreate the session if needed (status-only prompt — read-only)
tmux has-session -t "llm-$(basename $PWD)" 2>/dev/null || \
    NON_INTERACTIVE=1 $LLM_SANDBOX_DIR/llm-start.sh \
        "Status check ONLY — list worktrees and recent outcomes."

# 2. Spawn a listener window per worktree you'll act on
for issue in <list>; do
    WT=$(dirname $PWD)/wt-issue-$issue
    [ -d "$WT" ] || continue
    SESSION="llm-$(basename $PWD)"
    tmux list-windows -t "$SESSION" -F '#W' 2>/dev/null | grep -qx "iss-$issue" || \
        tmux new-window -d -t "$SESSION" -n "iss-$issue" \
            "$LLM_SANDBOX_DIR/sandbox.sh $WT listener"
done

# 3. Verify
tmux list-windows -t "llm-$(basename $PWD)"
```

Now `requeue.sh <issue> -` drops will be picked up within ~2 seconds.