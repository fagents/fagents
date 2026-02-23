#!/bin/bash
# uninstall-team.sh — Remove a team installed by install-team.sh
# Usage: sudo ./uninstall-team.sh [--infra USERNAME]
#
# Auto-detects team members from the 'fagent' group.
# Kills all running processes, removes users + home dirs, cleans up.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must run as root (sudo)." >&2
    exit 1
fi

INFRA_USER="${INFRA_USER:-fagents}"

# ── Parse args ──
while [[ $# -gt 0 ]]; do
    case "$1" in
        --infra) INFRA_USER="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# ── Find team members ──
if ! getent group fagent &>/dev/null; then
    echo "No 'fagent' group found — nothing to uninstall."
    exit 0
fi

# Get all users in the fagent group (primary group)
TEAM_USERS=()
while IFS=: read -r user _ uid gid _; do
    fagent_gid=$(getent group fagent | cut -d: -f3)
    if [[ "$gid" == "$fagent_gid" ]]; then
        TEAM_USERS+=("$user")
    fi
done < /etc/passwd

if [[ ${#TEAM_USERS[@]} -eq 0 ]]; then
    echo "No users in 'fagent' group — nothing to uninstall."
    exit 0
fi

echo "=== Freeturtle Team Uninstall ==="
echo ""
echo "  Infra user: $INFRA_USER"
echo "  Team users: ${TEAM_USERS[*]}"
echo ""
read -rp "Remove all these users and their data? [y/N] " confirm
if [[ "${confirm,,}" != "y" ]]; then
    echo "Aborted."
    exit 0
fi

echo ""

# ── Step 1: Stop all processes ──
echo "=== Step 1: Stop processes ==="
for user in "${TEAM_USERS[@]}"; do
    procs=$(pgrep -u "$user" 2>/dev/null || true)
    if [[ -n "$procs" ]]; then
        echo "  Killing processes for $user..."
        pkill -u "$user" 2>/dev/null || true
        sleep 1
        # Force kill stragglers
        pkill -9 -u "$user" 2>/dev/null || true
    fi
done
echo "  Done."
echo ""

# ── Step 2: Remove users ──
echo "=== Step 2: Remove users ==="
for user in "${TEAM_USERS[@]}"; do
    if id "$user" &>/dev/null; then
        userdel -r "$user" 2>/dev/null && echo "  Removed $user" || echo "  WARNING: could not fully remove $user"
    fi
    # Clean up sudoers
    rm -f "/etc/sudoers.d/$user"
done
echo ""

# ── Step 3: Remove group ──
echo "=== Step 3: Remove group ==="
groupdel fagent 2>/dev/null && echo "  Removed fagent group" || echo "  Group already gone"
echo ""

# ── Step 4: Clean up artifacts ──
echo "=== Step 4: Clean up ==="
rm -f /tmp/fagents-install-agent.sh
echo "  Cleaned /tmp artifacts"
echo ""

echo "=== Uninstall complete ==="
echo "Users removed: ${TEAM_USERS[*]}"
