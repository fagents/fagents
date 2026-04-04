#!/bin/bash
# setup-macos-vm.sh — Prepare a fresh macOS VM for fagents E2E testing
#
# Run this inside a macOS VM (UTM, Tart, etc.) as a regular user (not root).
# Installs Homebrew, bash 4+, and all prerequisites needed by the installer.
#
# After this script completes, run the E2E test:
#   sudo /opt/homebrew/bin/bash test-install-macos.sh
#
# Usage: bash setup-macos-vm.sh

set -euo pipefail

echo ""
echo "  fagents — macOS VM test setup"
echo ""

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ERROR: This script only runs on macOS." >&2
    exit 1
fi

if [[ $EUID -eq 0 ]]; then
    echo "ERROR: Don't run this as root. Run as a regular user." >&2
    exit 1
fi

# ── Homebrew ──
if command -v brew &>/dev/null; then
    echo "Homebrew already installed"
else
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Add to PATH for this session
    if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -f /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
fi

# ── Prerequisites ──
NEEDED=()
command -v git &>/dev/null     || NEEDED+=(git)
command -v python3 &>/dev/null || NEEDED+=(python3)
command -v curl &>/dev/null    || NEEDED+=(curl)
command -v jq &>/dev/null      || NEEDED+=(jq)
command -v node &>/dev/null    || NEEDED+=(node)

# Always ensure bash 4+ is available
if [[ -x /opt/homebrew/bin/bash ]]; then
    BASH_VER=$(/opt/homebrew/bin/bash -c 'echo ${BASH_VERSINFO[0]}')
    [[ "$BASH_VER" -ge 4 ]] || NEEDED+=(bash)
else
    NEEDED+=(bash)
fi

if [[ ${#NEEDED[@]} -gt 0 ]]; then
    echo "Installing: ${NEEDED[*]}"
    brew install "${NEEDED[@]}"
fi

# ── Verify ──
echo ""
echo "Checking prerequisites..."
OK=true
for cmd in git python3 curl jq node; do
    if command -v "$cmd" &>/dev/null; then
        echo "  $cmd: $(command -v $cmd)"
    else
        echo "  $cmd: MISSING"
        OK=false
    fi
done

BASH4="/opt/homebrew/bin/bash"
[[ -x "$BASH4" ]] || BASH4="/usr/local/bin/bash"
if [[ -x "$BASH4" ]]; then
    BASH_VER=$("$BASH4" -c 'echo ${BASH_VERSINFO[0]}')
    if [[ "$BASH_VER" -ge 4 ]]; then
        echo "  bash 4+: $BASH4 (version $BASH_VER)"
    else
        echo "  bash 4+: FAILED ($BASH4 is version $BASH_VER)"
        OK=false
    fi
else
    echo "  bash 4+: MISSING"
    OK=false
fi

echo ""
if $OK; then
    echo "Ready. Run the E2E test with:"
    echo "  sudo $BASH4 test-install-macos.sh"
else
    echo "Some prerequisites are missing. Fix the issues above and re-run."
    exit 1
fi
