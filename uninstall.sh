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

# ── Platform detection ──
OS="$(uname -s)"
case "$OS" in
    Linux)  UNINSTALLER="uninstall-team.sh" ;;
    Darwin) UNINSTALLER="uninstall-team-macos.sh" ;;
    *)      echo "ERROR: Unsupported OS: $OS" >&2; exit 1 ;;
esac

INSTALL_DIR="/tmp/fagents-uninstall-$$"
trap 'rm -rf "$INSTALL_DIR"' EXIT

echo "Fetching fagents..."
git clone --depth 1 --quiet https://github.com/fagents/fagents.git "$INSTALL_DIR"

echo ""
if [[ -e /dev/tty ]]; then
    "$INSTALL_DIR/$UNINSTALLER" "$@" < /dev/tty
else
    "$INSTALL_DIR/$UNINSTALLER" "$@"
fi
