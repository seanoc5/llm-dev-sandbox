# ADR-0001: Add `claude-code-action` as a third worker class

- **Status:** Accepted
- **Date:** 2026-05-05
- **Issue:** [#7](https://github.com/seanoc5/llm-swarm-runner/issues/7)
- **Deciders:** @seanoc5

## Context

Anthropic ships Claude Code as a GitHub Action (`anthropics/claude-code-action`) that runs on `@claude` mentions, label triggers, or `workflow_dispatch`. It is functionally similar to the workers this sandbox spawns, but executes on a GitHub-hosted (or self-hosted) runner instead of a local Docker container.

We already have two worker classes:

1. **Local tmux/Docker workers** — coordinator-provisioned, `--network host`, Claude Max OAuth via mounted `~/.claude`.
2. **Manual `sandbox.sh <project> claude`** — same environment, no coordinator.

The question: does `claude-code-action` replace or augment these?

## Forces

Three axes distinguish the execution models:

1. **Locality.** tmux workers run with `--network host` and reach real local services — Postgres on `5432`, Spring Boot apps on dev ports, OpenBrain MCP at `127.0.0.1:8100`. GH runners are isolated; reaching localhost services requires Tailscale, ngrok, or a self-hosted runner — each a non-trivial security/operational cost.
2. **Economics.** tmux workers inherit the host's `~/.claude/` config and run under the **Claude Max** OAuth plan: no per-request billing. `claude-code-action` runs against `ANTHROPIC_API_KEY` (or Bedrock/Vertex) — pay-per-token. For workloads we'd otherwise burn under Max, GH Actions is strictly more expensive.
3. **Presence.** tmux workers are observable live (`tmux a`, see the agent's output, interject). GH Actions runs are observable only post-hoc via the Actions log; mid-run intervention means cancel + push fix + retrigger. But GH Actions runs even when the host is off, sleeping, or under load — true offloading.

No single class wins all three.

## Decision

Adopt `claude-code-action` as a **third worker class** alongside tmux workers. Route by issue characteristic:

| Class                              | When                                                                                                                                    |
|------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------|
| tmux swarm (existing)              | Issues touching localhost services, MCP / OpenBrain integration, multi-step debugging, anything you intend to babysit, Max-plan economics preferred |
| `claude-code-action` (`@claude`)   | Small isolated issues — README/docs, dependency bumps, pure-logic test additions, anything CI alone can verify, overnight work          |
| Self-hosted runner on minti9       | **Rejected for now** — see "Rejected alternatives"                                                                                       |

The coordinator (`prompts/coordinator.md`) gains routing rules: read each issue, classify, then either `provision-worker.sh <N>` (tmux) or apply a `claude-action` label and let the workflow take it.

## Consequences

**Positive:**
- Trivial overnight / drive-by work no longer occupies the local swarm.
- Collaborators on the same repo can invoke `@claude` without access to your tmux session.
- GH Actions logs become a built-in audit trail for the Actions-class worker — no `sweep-swarm-outcomes.sh` equivalent needed for that class.
- The local swarm reclaims focus for the work that actually needs `--network host`.

**Negative:**
- Two control planes to reason about. Routing mistakes cost API tokens (sending Max-eligible work to Actions) or block on host availability (sending offloadable work to tmux).
- API-key exposure surface: any repo using the workflow needs `ANTHROPIC_API_KEY` in its secrets. Public-repo `pull_request_target` flows are a known supply-chain risk and require per-project hardening (label/author allowlists).
- MCP integration (OpenBrain) is unavailable on the Actions class without exposing the server publicly — a security cost we are not willing to pay.

**Neutral:**
- Coordinator prompt grows; routing logic is a few sentences and one shell-command branch.

## Rejected alternatives

- **Replace tmux workers with `claude-code-action` everywhere.** Loses `--network host` access to local Postgres / Spring Boot / MCP — the core feature of this sandbox. Also forfeits Claude Max economics. Hard no.
- **Self-hosted runner on minti9.** Combines GH-event triggering with host network access. Tempting, but: (a) defeats the offloading premise — runs still consume the host; (b) introduces a third control plane (GH webhook → runner → host) for marginal benefit; (c) opens an inbound trust path from GH's webhook delivery into your host. Revisit only if overnight host-coupled runs become load-bearing.
- **Auto-routing (coordinator picks the class).** Premature. The classifier needs calibration data we don't have yet. Manual labeling first; promote to auto only after 2–3 months of routing data.
- **Cost/usage telemetry across both classes.** Worthwhile but separable; track in a follow-up.

## Implementation notes

Implementation lands in fix/issue-7:

1. This ADR.
2. `examples/github-workflows/claude-code.yml.example` — copy-paste template for target projects, including label-trigger config and a security-hardening checklist.
3. Coordinator prompt update — adds the routing classification step and the `gh issue edit --add-label claude-action` shell call as the alternative to `provision-worker.sh`.
4. Brief mention in `docs/architecture.md` linking back to this ADR so the trade-off discoverable from the architecture overview.

## References

- Anthropic: [`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action)
- Conversation that prompted this ADR: 2026-05-05 review of `llm-swarm-runner` vs GH Actions.
