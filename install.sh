#!/bin/bash
# fagents installer — curlable bootstrap script
# Usage: curl -fsSL https://fagents.ai/install.sh | bash
#
# Downloads fagents-autonomy and runs install-agent.sh interactively.

set -euo pipefail

echo ""
echo "  fagents — free agents"
echo "  https://fagents.ai"
echo ""

# Check prerequisites
for cmd in git python3 curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd is required but not installed." >&2
        exit 1
    fi
done

INSTALL_DIR="${FAGENTS_DIR:-$HOME/workspace/fagents-autonomy}"

if [[ -d "$INSTALL_DIR" ]]; then
    echo "fagents-autonomy already exists at $INSTALL_DIR"
    echo "Pulling latest..."
    git -C "$INSTALL_DIR" pull --quiet 2>/dev/null || echo "  (pull failed, using existing)"
else
    echo "Cloning fagents-autonomy..."
    git clone https://github.com/fagents/fagents-autonomy.git "$INSTALL_DIR"
fi

echo ""
echo "Running install-agent.sh..."
echo ""
bash "$INSTALL_DIR/install-agent.sh"
