# Architecture & Orchestration

This document outlines the design philosophy and technical architecture of the `llm-dev-sandbox` multi-agent system.

## The 2026 Pattern: Git Worktree Isolation

As LLMs have reached 1M+ token contexts (e.g., Claude 4.7, Gemini 1.5 Pro), the industry standard for multi-agent development has shifted from complex micro-container orchestration to **Git Worktree Isolation**. 

This pattern solves two major problems in multi-agent environments:
1.  **File Lock Contention:** Agents attempting to edit the same file simultaneously corrupt source code.
2.  **Context Pollution:** Reading a file that another agent is half-way through refactoring breaks the first agent's mental model.

By using Git Worktrees, each agent gets a physically separate clone of the repository on the filesystem, checked out to a unique branch, while sharing the underlying `.git` object database. They can compile, break, and refactor their own branch without impacting the main branch or other agents.

## Coordinator -> Worker Architecture

This sandbox supports a fully autonomous architecture managed via `tmux`:

1.  **The Coordinator (Brain):** A dedicated `tmux` session is bootstrapped by `llm-start.sh`, dropping you directly into Gemini CLI (Window 1). Gemini acts as an autonomous project manager. It uses `gh` to read your backlog, plans tasks, and dynamically creates Git worktrees on the fly.
2.  **The Workers (Hands):** The Coordinator autonomously provisions background `tmux` windows containing isolated Claude Code sandboxes.
3.  **The Communication:** The Coordinator assigns tasks by dropping highly detailed `.agent-task.md` specs into the worktrees. A background `worker-listener.sh` daemon immediately picks them up and executes them, while the Coordinator monitors their PR output via `gh`.

## Open Source Landscape & Alternatives

While you can build complex systems using Python frameworks like **CrewAI** or **LangGraph**, those frameworks often lack safe execution environments. This sandbox provides the missing execution layer.

If you are looking for fully pre-built orchestration tools rather than this custom shell/tmux approach, consider:
*   **Composio Agent Orchestrator (AO):** Best for enterprise-level, fully autonomous PR handling and CI fixing across worktrees.
*   **Claude Squad:** A terminal-based orchestrator very similar to this project, focusing on `tmux` session management for solo developers.
*   **Dagger (Container Use):** Focuses on high-security, headless container execution rather than interactive tmux windows.

**General Similar Projects & Resources:**
*   **Cloud-based:** [E2B (Secure sandboxes for AI agents)](https://e2b.dev/), [Daytona (Standardized Dev Environments)](https://www.daytona.io/), [Replit Deployments](https://replit.com/)
*   **Localhost/Docker-based:** [Devcontainers](https://containers.dev/), [Runme](https://runme.dev/)
*   **Further Reading:** [Anthropic's research on AI safety and containment](https://www.anthropic.com/research), [OWASP Top 10 for LLM Applications](https://owasp.org/www-project-top-10-for-large-language-model-applications/)