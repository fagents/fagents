#!/bin/bash
# setup-linux-vm-prereqs.sh — Prepare a fresh Linux VM for fagents E2E testing
#
# Run this inside a Linux VM as root.
# Installs git, python3, curl, jq — everything the installer needs.
#
# Usage: sudo bash setup-linux-vm-prereqs.sh

set -euo pipefail

echo ""
echo "  fagents — Linux VM test setup"
echo ""

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "ERROR: This script only runs on Linux." >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must run as root (sudo)." >&2
    exit 1
fi

# ── Install prerequisites ──
NEEDED=()
command -v git     &>/dev/null || NEEDED+=(git)
command -v python3 &>/dev/null || NEEDED+=(python3)
command -v curl    &>/dev/null || NEEDED+=(curl)
command -v jq      &>/dev/null || NEEDED+=(jq)

if [[ ${#NEEDED[@]} -gt 0 ]]; then
    echo "Installing: ${NEEDED[*]}"
    apt-get update -qq 2>/dev/null
    apt-get install -y "${NEEDED[@]}"
fi

# ── Verify ──
echo ""
echo "Checking prerequisites..."
OK=true
for cmd in git python3 curl jq bash; do
    if command -v "$cmd" &>/dev/null; then
        echo "  $cmd: $(command -v $cmd)"
    else
        echo "  $cmd: MISSING"
        OK=false
    fi
done

echo ""
if $OK; then
    echo "Ready. Run the E2E test with:"
    echo "  sudo bash test-install-linux.sh"
else
    echo "Some prerequisites are missing. Fix the issues above and re-run."
    exit 1
fi
