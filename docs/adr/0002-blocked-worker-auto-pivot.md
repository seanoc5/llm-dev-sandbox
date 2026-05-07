# ADR-0002: Auto-pivot blocked workers into an interactive REPL

- **Status:** Accepted
- **Date:** 2026-05-07
- **Deciders:** @seanoc5

## Context

A worker (claude inside `wt-issue-N`) sometimes can't finish its task autonomously: the brief is ambiguous, the env is broken in an unexpected way, an assumption embedded in the issue body turns out to be wrong, etc. Until now the listener treated every worker run as binary: `outcome=ok` (rc=0) or `outcome=err` (rc≠0). Both states moved the brief to `done/` and went back to polling the inbox.

That meant a "blocked" worker — one that exited because it ran out of moves but still has perfectly good loaded context — was indistinguishable from a "failed" worker (real exception). The coordinator's only signal was the outcome JSON's `error` field, which a human had to read post-hoc and then re-issue the task with clarifications, losing the original conversation in the process.

The user's stated intent: "leave that worker running, with the issue in context, and problem echoed out for the human (me) to read, and work through with claude (in the existing session)."

## Forces

1. **Context preservation.** claude-code persists per-cwd session state in `~/.claude/projects/<cwd-hash>/<session-id>.jsonl`. `claude --continue` reloads the entire prior conversation — system prompt, tool calls, file reads, partial diffs. Throwing this away on rc≠0 is wasteful when the conversation is the most expensive thing about the run.
2. **Default-mode mismatch.** Workers run with `WORKER_HEADLESS=0` (interactive) by default. In that mode claude already drops to REPL after running the seeded prompt — a "blocker pivot" is redundant because the REPL already exists. In `WORKER_HEADLESS=1` mode (e2e tests, CI, anything unattended) claude exits and the loaded context is lost without intervention.
3. **Capacity vs. visibility.** A blocked worker holds a `MAX_WORKERS` slot indefinitely. We accept that cost in exchange for not losing context. But the coordinator needs to *see* which workers are blocked to surface them in heartbeats and triage prompts — otherwise the user has to scan tmux windows manually.
4. **Single-dev / two-flow scope.** This ADR is written for the single-developer case (or two devs with logically separate projects). Multi-developer collaborative scenarios — where one human's blocker session might race another's — are out of scope; revisit if that ever applies.

## Decision

Add a third terminal state to the worker contract: **blocked**.

The contract:

1. The brief instructs claude (in the Completion Protocol section) to write `<wt>/.swarm/tasks/blocked/<task_id>.md` if it cannot finish — explaining what's blocking — *before* terminating.
2. After the dispatched agent exits, the listener checks for that marker. If present:
   - **Headless mode (`WORKER_HEADLESS=1`):** the listener auto-pivots — prints a banner with the blocker content and `exec`s `claude --continue --dangerously-skip-permissions`, blocking until the user attaches and `/quit`s. The full prior conversation is reloaded.
   - **Interactive mode (default, `WORKER_HEADLESS=0`):** claude already dropped to REPL with full context, so no pivot is needed. The marker exists only as an observability signal.
3. The outcome JSON gains a `blocked: true|false` field alongside `outcome` so downstream tooling (sweep, coordinator, watcher heartbeats) can distinguish blocked-then-resolved from clean-success.
4. `coordinator-watch.sh` watches `.swarm/tasks/blocked/` directories alongside `done/` and surfaces a `blocked=N` count in the heartbeat line.

## Consequences

**Positive:**
- Loaded conversation context is preserved across the human-in-the-loop boundary in headless mode.
- The coordinator can prioritize human attention to blocked workers instead of treating them as generic idle slots.
- The interactive default is unchanged — existing reflexive workflows keep working.
- The brief change is additive; workers that already commit + open PRs are unaffected.

**Negative:**
- A blocked worker holds its `MAX_WORKERS` slot until a human attends. In `--yolo` overnight runs this can stall the swarm. Mitigation: a future `--max-blocked-age` reaper that auto-converts old blocked markers to `outcome=err` and frees the slot.
- Three-state outcomes are slightly more complex to script around than two. Mitigated by keeping `outcome` as the binary `ok|err` field plus a separate `blocked` bool — pre-existing consumers don't need to change.
- A worker can theoretically *both* commit work and write a blocker marker (partial progress + question). The contract treats marker-presence as authoritative: if marker exists, state is blocked, regardless of commits. Consumers wanting "blocked-with-progress" can read the file content.

**Neutral:**
- New event types in `events.log`: `worker.blocked`, `worker.blocked.resolved`. No format break.

## Rejected alternatives

- **Explicit pivot (user-driven).** Same marker contract, but the listener does *not* auto-`claude --continue`. Instead the watcher surfaces blocked workers and the user runs `iss-resume <N>` (a new helper) to deliberately pull a blocker into REPL. Pros: bulk-deferral works ("file 5 issues, get blocked on 3, resolve all 3 tomorrow"), worker can in the meantime free its slot if the user decides to abandon. Cons: more steps in the common case, more state to manage. **Revisit if** the swarm grows past one developer's attention budget — at swarm sizes where bulk-deferral becomes the norm, the auto-pivot becomes more cost than benefit.

- **Always run workers headless.** Would make the auto-pivot the only path. Rejected because the interactive default is genuinely useful: the user can intervene at any point during a task, not just at the post-hoc blocker boundary.

- **Encode "blocked" as a third file extension (`*.blocked.json` in `done/`).** Cleaner naming but requires updating every consumer that scans `*.{ok,err}.json`. The "marker file in `blocked/` + flag in outcome JSON" approach lets existing consumers keep working unchanged.

## Implementation

- `scripts/provision-worker.sh` — brief template gains a "Completion Protocol" + "Blocker Escalation" section between the policy block and the task block.
- `scripts/worker-listener.sh` — adds the post-agent blocker check and the headless auto-pivot. Tags outcome JSON with `blocked` field.
- `scripts/coordinator-watch.sh` — extends polling to `.swarm/tasks/blocked/`, adds `worker.blocked` event, includes blocked count in heartbeat.

## Future signals to revisit this ADR

- Frequent stale blocked markers (>24h old) → consider the explicit-pivot alternative or add a reaper.
- Multi-developer workflows on the same project → revisit; auto-pivot races are possible.
- A blocker class that's almost always the same question (e.g., "ANTHROPIC_API_KEY missing") → answer it at brief-build time instead of escalating.
