#!/bin/bash
# fagents uninstaller — curlable
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/fagents/fagents/main/uninstall.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/fagents/fagents/main/uninstall.sh | sudo bash -s -- --yes
#
# Downloads fagents and runs uninstall-team.sh.

set -euo pipefail

echo ""
echo "  fagents — uninstaller"
echo "  https://fagents.ai"
echo ""

if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: This script must be run as root (use sudo)." >&2
    exit 1
fi

for cmd in git; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' is required but not installed." >&2
        exit 1
    fi
done

INSTALL_DIR="/tmp/fagents-uninstall-$$"
trap 'rm -rf "$INSTALL_DIR"' EXIT

echo "Fetching fagents..."
git clone --depth 1 --quiet https://github.com/fagents/fagents.git "$INSTALL_DIR"

echo ""
"$INSTALL_DIR/uninstall-team.sh" "$@" < /dev/tty
