#!/bin/bash
# fagents installer — curlable bootstrap script
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/fagents/fagents/main/install.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/fagents/fagents/main/install.sh | sudo bash -s -- --template business
#
# Downloads fagents and runs install-team.sh with any arguments passed through.

set -euo pipefail

echo ""
echo "  fagents — free agents"
echo "  https://fagents.ai"
echo ""

# ── Preflight ──
if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: This script must be run as root (use sudo)." >&2
    exit 1
fi

# ── Platform detection ──
OS="$(uname -s)"
case "$OS" in
    Linux)  INSTALLER="install-team.sh" ;;
    Darwin) INSTALLER="install-team-macos.sh" ;;
    *)      echo "ERROR: Unsupported OS: $OS" >&2; exit 1 ;;
esac

if [[ "$OS" == "Darwin" ]]; then
    # macOS: can't brew install as root — check only
    _missing=()
    for cmd in git python3 curl jq; do
        command -v "$cmd" &>/dev/null || _missing+=("$cmd")
    done
    if [[ ${#_missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing prerequisites: ${_missing[*]}" >&2
        echo "       Install with Homebrew (as your normal user, not root):" >&2
        echo "       brew install ${_missing[*]}" >&2
        exit 1
    fi
else
    # Linux: install missing prereqs via apt
    _missing=()
    for cmd in git python3 curl jq; do
        command -v "$cmd" &>/dev/null || _missing+=("$cmd")
    done
    if [[ ${#_missing[@]} -gt 0 ]]; then
        echo "Installing prerequisites: ${_missing[*]}"
        apt-get update -qq 2>/dev/null || true
        apt-get install -y "${_missing[@]}" 2>/dev/null || true
        for cmd in "${_missing[@]}"; do
            if ! command -v "$cmd" &>/dev/null; then
                echo "ERROR: '$cmd' is required but could not be installed." >&2
                echo "       Try: apt-get install -y $cmd" >&2
                exit 1
            fi
        done
    fi
fi

# ── Clone ──
INSTALL_DIR="/tmp/fagents-install-$$"
trap 'rm -rf "$INSTALL_DIR"' EXIT

echo "Fetching fagents..."
git clone --depth 1 --quiet https://github.com/fagents/fagents.git "$INSTALL_DIR"

# ── Run installer ──
echo ""
if [[ -n "${NONINTERACTIVE:-}" ]]; then
    "$INSTALL_DIR/$INSTALLER" "$@"
elif [[ -e /dev/tty ]]; then
    "$INSTALL_DIR/$INSTALLER" "$@" < /dev/tty
else
    echo "ERROR: No terminal available for interactive setup." >&2
    echo "       Set NONINTERACTIVE=1 with required env vars, or run from a terminal." >&2
    exit 1
fi
