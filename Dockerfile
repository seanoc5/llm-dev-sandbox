FROM buildpack-deps:noble

ARG DEBIAN_FRONTEND=noninteractive

# buildpack-deps:noble already provides:
#   build-essential, curl, wget, git, ca-certificates, gnupg, and a large set of dev libs.
#
# ubuntu-standard fills in the Linux userland (man pages, common utilities, etc.).
# Intentionally NO --no-install-recommends here — the recommended packages are the point.
RUN apt-get update \
    && apt-get install -y ubuntu-standard \
    && rm -rf /var/lib/apt/lists/*

# Tools not covered by buildpack-deps or ubuntu-standard
RUN apt-get update && apt-get install -y --no-install-recommends \
    jq ripgrep fd-find unzip zip sudo \
    openssh-client \
    postgresql-client \
    less vim tree htop \
    iproute2 net-tools \
    && rm -rf /var/lib/apt/lists/*

# JDK 21
RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-21-jdk-headless \
    && rm -rf /var/lib/apt/lists/*

# Node 22 via NodeSource
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Deno
RUN curl -fsSL https://deno.land/install.sh | DENO_INSTALL=/usr/local sh

# Python 3 + uv (python3 may already be present; uv is not)
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# LLM CLIs & Tools
RUN npm install -g @anthropic-ai/claude-code @google/gemini-cli @openai/codex promptfoo

# Docker CLI (for DooD — Testcontainers and general docker commands)
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
       https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
    > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user matching host UID
ARG HOST_UID=1000
ARG HOST_GID=1000
RUN groupadd -f -g ${HOST_GID} sandbox \
    && useradd -m -u ${HOST_UID} -g ${HOST_GID} -s /bin/bash sandbox 2>/dev/null \
    || usermod -u ${HOST_UID} -g ${HOST_GID} -d /home/sandbox -m -l sandbox ubuntu 2>/dev/null; \
    echo "sandbox ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/sandbox

# Entrypoint: registers host docker group GID at container start
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Configure NPM global for the sandbox user
RUN mkdir -p /home/sandbox/.npm-global \
    && chown -R sandbox:sandbox /home/sandbox/.npm-global
ENV NPM_CONFIG_PREFIX=/home/sandbox/.npm-global
ENV PATH="/home/sandbox/.npm-global/bin:/home/sandbox/.local/bin:${PATH}"

# Pre-create cache directories and set permissions
RUN mkdir -p /home/sandbox/.npm /home/sandbox/.cache/pip /home/sandbox/.cache/uv \
    && chown -R sandbox:sandbox /home/sandbox

# Add aliases for LLM CLIs
RUN echo "alias claude='claude --dangerously-skip-permissions'" >> /home/sandbox/.bashrc \
    && echo "alias gemini='gemini --yolo'" >> /home/sandbox/.bashrc

USER sandbox
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
