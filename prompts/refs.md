# Reference Docs (MUST CONSULT WHEN TRIGGERED)

This is the **reference-docs index** available to you in this sandbox. When you encounter one of the triggers below, **stop and read the referenced doc before acting** — its content is more authoritative and current than your model knowledge. Reading takes seconds; making the wrong move because you "thought you remembered" costs much more.

Each doc lives under `$LLM_SWARM_DOCS/` (a read-only bind mount inside your container). Read with `cat "$LLM_SWARM_DOCS/<path>"`. The env var is set; if for some reason it's not, the absolute path is also fine — it matches the host path.

## How to use this index

1. **Scan** the trigger column on every brief — keep these in working memory.
2. **When a trigger fires**, read the entire referenced doc (`cat`, not skim).
3. **Apply** what it says directly. Don't paraphrase from memory; if you're typing a command, the doc has the canonical form.
4. **If the doc doesn't cover your case**, surface it in your end-of-work summary as a `## Note` block ("ref docs didn't cover X — worth an addition") so the index can grow.

You may encounter a doc whose advice conflicts with something in `.swarm-policy.md` or the active brief — those win. Reference docs are general guidance; project policy and per-task instructions are specific.

## Available references

| When you encounter… | Read |
|---|---|
| A git merge conflict, rebase decision, lost-commit recovery, or any non-trivial git/`gh` operation you're unsure about | `$LLM_SWARM_DOCS/VCS/git-github.md` |

(More refs will be added as patterns emerge. Project-specific refs may be appended via `.swarm-policy.md`.)
