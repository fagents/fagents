#!/bin/bash
# uninstall-team-macos.sh — Remove a team installed by install-team-macos.sh
#
# Usage: sudo ./uninstall-team-macos.sh [--yes]
#
# Auto-detects team members from the 'fagent' group.
# Kills all running processes, removes users + home dirs, cleans up.
# Pass --yes to skip confirmation prompt.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must run as root (sudo)." >&2
    exit 1
fi

INFRA_USER="fagents"
GROUP="fagent"
AUTO_YES=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y) AUTO_YES=1; shift ;;
        --help|-h)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# ── Find team members ──
if ! dscl . -read /Groups/"$GROUP" &>/dev/null; then
    echo "No '$GROUP' group found — nothing to uninstall."
    exit 0
fi

fagent_gid=$(dscl . -read /Groups/"$GROUP" PrimaryGroupID 2>/dev/null | awk '{print $2}')
if [[ -z "$fagent_gid" ]]; then
    echo "No '$GROUP' group found — nothing to uninstall."
    exit 0
fi

TEAM_USERS=()
while IFS= read -r line; do
    user=$(echo "$line" | awk '{print $1}')
    ugid=$(echo "$line" | awk '{print $2}')
    if [[ "$ugid" == "$fagent_gid" ]]; then
        TEAM_USERS+=("$user")
    fi
done < <(dscl . -list /Users PrimaryGroupID 2>/dev/null)

if [[ ${#TEAM_USERS[@]} -eq 0 ]]; then
    echo "No users in '$GROUP' group — nothing to uninstall."
    exit 0
fi

# Split into infra and agents
AGENT_USERS=()
for user in "${TEAM_USERS[@]}"; do
    [[ "$user" != "$INFRA_USER" ]] && AGENT_USERS+=("$user")
done

echo ""
echo "  fagents — uninstaller (macOS)"
echo ""
echo "  Will remove:"
echo "    Infra user: $INFRA_USER"
if [[ ${#AGENT_USERS[@]} -gt 0 ]]; then
    echo "    Agents:     ${AGENT_USERS[*]}"
fi
echo "    Group:      $GROUP"
echo "    All home directories, repos, workspaces, and data"
echo ""

if [[ -z "$AUTO_YES" ]]; then
    read -rp "  Continue? [y/N] " confirm
    if [[ ! "${confirm,,}" =~ ^y ]]; then
        echo "  Aborted."
        exit 0
    fi
fi

echo ""

# ── Step 1: Stop processes ──
echo "=== Step 1: Stop processes ==="

# Stop comms server + infra processes
if id "$INFRA_USER" &>/dev/null; then
    if pgrep -u "$INFRA_USER" &>/dev/null; then
        echo "  Stopping $INFRA_USER processes..."
        pkill -u "$INFRA_USER" 2>/dev/null || true
        sleep 1
        pkill -9 -u "$INFRA_USER" 2>/dev/null || true
    fi
fi

# Stop agent processes
for user in "${AGENT_USERS[@]}"; do
    if pgrep -u "$user" &>/dev/null; then
        echo "  Stopping $user processes..."
        pkill -u "$user" 2>/dev/null || true
        sleep 1
        pkill -9 -u "$user" 2>/dev/null || true
    fi
done
echo "  Done."
echo ""

# ── Step 2: Remove users ──
echo "=== Step 2: Remove users ==="
for user in "${AGENT_USERS[@]}"; do
    if id "$user" &>/dev/null; then
        rm -f "/etc/sudoers.d/$user"
        rm -f "/etc/sudoers.d/${user}-telegram"
        dscl . -delete /Users/"$user" 2>/dev/null && echo "  Removed user: $user" || echo "  WARNING: could not remove user $user"
        rm -rf /Users/"$user"
    fi
done
if id "$INFRA_USER" &>/dev/null; then
    dscl . -delete /Users/"$INFRA_USER" 2>/dev/null && echo "  Removed user: $INFRA_USER" || echo "  WARNING: could not remove $INFRA_USER"
    rm -rf /Users/"$INFRA_USER"
fi
echo ""

# ── Step 3: Remove group + cleanup ──
echo "=== Step 3: Clean up ==="
dscl . -delete /Groups/"$GROUP" 2>/dev/null && echo "  Removed $GROUP group" || echo "  Group already gone"

# Clean /etc/gitconfig safe.directory
if [[ -f /etc/gitconfig ]] && grep -q 'directory = \*' /etc/gitconfig 2>/dev/null; then
    sed -i '' '/^\[safe\]$/d; /directory = \*/d' /etc/gitconfig 2>/dev/null || true
    [[ ! -s /etc/gitconfig ]] && rm -f /etc/gitconfig
    echo "  Cleaned /etc/gitconfig"
fi
echo ""

echo "=== Uninstall complete ==="
echo ""
echo "  To reinstall:"
echo "  curl -fsSL https://raw.githubusercontent.com/fagents/fagents/main/install.sh | sudo bash"
echo ""
