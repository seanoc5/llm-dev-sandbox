# Security Considerations

When giving an autonomous AI tool access to your filesystem, security must be a primary concern. This document outlines the security boundaries and risks associated with `llm-dev-sandbox`.

## Core Security Model

*   **Runs as your host UID/GID:** The sandbox runs processes using your exact User ID and Group ID. This ensures file permissions inside and outside the container match perfectly, but it also means the agent has the exact same file-level access rights as you do for any mounted directories.
*   **Containment via Mounts:** The blast radius is limited strictly to the directories you bind-mount. By default, this is only the `$PROJECT_DIR`. The agent cannot accidentally `rm -rf /` your host machine.

## Known Risks and Caveats

### `--dangerously-skip-permissions` / `--yolo`
Claude Code and Gemini CLI run in auto-approve mode inside the sandbox. This is the primary reason the sandbox exists. However, review what the agent is doing periodically. The sandbox does not prevent destructive file operations (like deleting all your source files) *within the mounted project directory*.

### Network Host Mode (`--network host`)
The container shares the host network stack. This is incredibly convenient for local development (e.g., the agent can connect to `localhost:5432` to query your local Postgres database), but it means the container is not network-isolated. 
*   **Risk:** An agent could theoretically attempt to interact with other local services running on your machine.
*   **Suitability:** This is appropriate for a local dev tool running trusted code on your workstation. It is **not** suitable for running entirely untrusted workloads or internet-facing services.

### Docker-outside-of-Docker (DooD)
Mounting `/var/run/docker.sock` gives the container full Docker daemon access. This is inherent to the DooD pattern and unavoidable if you need Testcontainers or the ability to build Docker images inside the sandbox.
*   **Risk:** Anyone with access to the Docker socket can theoretically achieve root access to the host machine by spinning up a privileged container. 

### Read-Only Credentials
*   **SSH keys:** Mounted `ro` (read-only). The agent can use them to sign commits or push to GitHub, but it cannot modify them.
*   **Exfiltration:** While credentials cannot be modified, an actively malicious agent *could* theoretically read them and exfiltrate them via the network. You must trust the LLM provider (Anthropic, Google) you are using.