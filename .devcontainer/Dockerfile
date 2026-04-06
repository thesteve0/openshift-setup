FROM registry.fedoraproject.org/fedora:latest

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# 1. System packages
RUN dnf install -y --setopt=install_weak_deps=False \
        curl \
        git \
        openssh-clients \
        sudo \
        findutils \
        which \
        bash \
        shadow-utils \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# 2. UV — system-wide via Astral native installer
ENV UV_INSTALL_DIR=/usr/local/bin
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# 3. UV global env — must precede all uv commands
#    UV_TOOL_DIR: world-readable path (default /root/.local is NOT readable by developer user)
#    UV_TOOL_BIN_DIR: executables at /usr/local/bin (on default PATH, visible to non-interactive shells)
ENV UV_TOOL_DIR=/usr/local/share/uv/tools \
    UV_TOOL_BIN_DIR=/usr/local/bin \
    UV_PYTHON_INSTALL_DIR=/usr/local/share/uv/python \
    UV_PYTHON=3.14 \
    UV_NO_PROGRESS=1 \
    UV_LINK_MODE=copy

# 4. Python 3.14 via UV (no system Python, no pip)
#    Symlink into /usr/local/bin so bare `python` and `python3` resolve system-wide
RUN uv python install 3.14 \
    && PYTHON_BIN=$(uv python find 3.14) \
    && ln -s "$PYTHON_BIN" /usr/local/bin/python \
    && ln -s "$PYTHON_BIN" /usr/local/bin/python3 \
    && uv cache clean

# 5. developer user (uid 1000, passwordless sudo)
#    common-utils devcontainer feature is Debian/Ubuntu-only so we create the user here
RUN useradd -m -s /bin/bash -u 1000 developer \
    && usermod -aG wheel developer \
    && echo "developer ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/developer \
    && chmod 0440 /etc/sudoers.d/developer

# 6. Astral tools — ruff and ty
#    Executables land at /usr/local/bin/ruff and /usr/local/bin/ty via UV_TOOL_BIN_DIR
RUN uv tool install ruff \
    && uv tool install ty \
    && uv cache clean

# 7. Workspace directory
RUN mkdir -p /workspaces \
    && chown developer:developer /workspaces

# 8. Claude Code — native installer, run as developer so it lands in
#    /home/developer/.local/bin/claude which is already first on developer's PATH.
#    /root/.local is mode 700 and unreachable by developer, so root installs won't work.
USER developer
RUN curl -fsSL https://claude.ai/install.sh | bash

WORKDIR /workspaces
