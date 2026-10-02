ARG NODE_VERSION=22
FROM node:${NODE_VERSION}-bookworm

ARG TZ=Etc/UTC
ENV TZ="$TZ"

# Pin this to a specific version (e.g. 2.1.0) if you want reproducible images.
ARG CLAUDE_CODE_VERSION=latest

# --- system packages -------------------------------------------------------
# iptables/ipset/dnsutils/aggregate are only needed by init-firewall.sh.
RUN apt-get update \
    && export DEBIAN_FRONTEND=noninteractive \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg2 \
        git less procps sudo unzip man-db \
        zsh fzf ripgrep jq \
        iptables ipset iproute2 dnsutils aggregate \
    && rm -rf /var/lib/apt/lists/*

# --- GitHub CLI ------------------------------------------------------------
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# --- Azure CLI ---------------------------------------------------------
RUN curl -sLS https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor \
        -o /usr/share/keyrings/microsoft-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/microsoft-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/microsoft-archive-keyring.gpg] https://packages.microsoft.com/repos/azure-cli/ bookworm main" \
        > /etc/apt/sources.list.d/azure-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends azure-cli \
    && rm -rf /var/lib/apt/lists/*

# --- PowerShell --------------------------------------------------------
# Reuses the Microsoft keyring fetched above for azure-cli; both repos are
# signed with the same key.
RUN echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/microsoft-archive-keyring.gpg] https://packages.microsoft.com/debian/12/prod bookworm main" \
        > /etc/apt/sources.list.d/microsoft-prod.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends powershell \
    && rm -rf /var/lib/apt/lists/*

# --- Az PowerShell module ---------------------------------------------------
# Installed for AllUsers so it's available to every user account without a
# per-profile install step. Trusting PSGallery first skips the interactive
# "untrusted repository" prompt that a non-interactive shell can't answer.
RUN pwsh -NoLogo -NonInteractive -Command \
        "Set-PSRepository -Name PSGallery -InstallationPolicy Trusted; \
         Install-Module -Name Az -Repository PSGallery -Scope AllUsers -Force"

# --- Terraform --------------------------------------------------------------
# Pin with TERRAFORM_VERSION (e.g. 1.16.2) for reproducible images.
ARG TERRAFORM_VERSION=latest
RUN curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor \
        -o /usr/share/keyrings/hashicorp-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/hashicorp-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com bookworm main" \
        > /etc/apt/sources.list.d/hashicorp.list \
    && apt-get update \
    && if [ "$TERRAFORM_VERSION" = "latest" ]; then pkg=terraform; else pkg="terraform=${TERRAFORM_VERSION}-*"; fi \
    && apt-get install -y --no-install-recommends "$pkg" \
    && rm -rf /var/lib/apt/lists/* \
    && terraform version

# --- writable locations for the non-root `node` user -----------------------
# /commandhistory and /home/node/.claude are backed by named volumes so shell
# history and Claude's login/session state survive a container rebuild.
RUN mkdir -p /commandhistory /home/node/.claude /usr/local/share/npm-global \
    && touch /commandhistory/.zsh_history \
    && chown -R node:node /commandhistory /home/node/.claude /usr/local/share/npm-global

ENV DEVCONTAINER=true \
    NPM_CONFIG_PREFIX=/usr/local/share/npm-global \
    PATH=/usr/local/share/npm-global/bin:$PATH \
    SHELL=/bin/zsh

# Login shells source /etc/profile, which overwrites PATH and would otherwise
# hide the globally installed `claude` binary.
RUN echo 'export PATH=/usr/local/share/npm-global/bin:$PATH' > /etc/profile.d/npm-global.sh \
    && chmod 0644 /etc/profile.d/npm-global.sh

# --- egress firewall -------------------------------------------------------
# `node` may run exactly this one command as root, nothing else.
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod 0755 /usr/local/bin/init-firewall.sh \
    && echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/node-firewall \
    && chmod 0440 /etc/sudoers.d/node-firewall

USER node

COPY --chown=node:node zshrc /home/node/.zshrc

RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

WORKDIR /workspace
