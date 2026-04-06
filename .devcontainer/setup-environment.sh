#!/bin/bash
set -e

echo "=== Python Dev (Fedora) — Post-Create Setup ==="

# Verify tool installations
echo "Tool versions:"
uv --version
ruff --version
ty --version
claude --version
echo "Python: $(uv run python --version)"

# Create project virtual environment with Python 3.14
# This satisfies VIRTUAL_ENV=${containerWorkspaceFolder}/.venv expected by IDEs
if [ ! -d "${VIRTUAL_ENV}" ]; then
    echo "Creating .venv with Python 3.14..."
    uv venv --python 3.14 "${VIRTUAL_ENV}"
fi

# If project already has a pyproject.toml, sync dependencies
if [ -f "pyproject.toml" ]; then
    echo "Found pyproject.toml — syncing dependencies..."
    uv sync
fi

# Copy host gitconfig to a writable location
# (direct bind mount of a file blocks git's atomic writes)
if [ -f /tmp/host-gitconfig ]; then
    cp /tmp/host-gitconfig "${HOME}/.gitconfig"
    echo "Git config: copied from host"
fi

# SSH agent status
if [ -S "${SSH_AUTH_SOCK}" ]; then
    echo "SSH agent: OK"
else
    echo "WARNING: SSH agent not available (SSH_AUTH_SOCK=${SSH_AUTH_SOCK})"
    echo "  Ensure ssh-agent is running on host before rebuilding the container"
fi

echo "=== Setup complete ==="
