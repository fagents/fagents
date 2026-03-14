#!/bin/bash
# add-email.sh — Add email credentials for an agent to fagents-mcp
#
# Interactive (human):  sudo bash add-email.sh
# Non-interactive (agent): sudo bash add-email.sh --agent \
#   --name AgentName --token TOKEN --from agent@example.com \
#   --smtp-user user --smtp-pass pass --imap-user user --imap-pass pass
#
# Requires: jq, running fagents-mcp service

set -euo pipefail

INFRA_USER="fagents"
INFRA_HOME=$(eval echo "~$INFRA_USER")
MCP_DIR="$INFRA_HOME/workspace/fagents-mcp"
AGENTS_JSON="$MCP_DIR/agents.json"

# ── Parse flags ──
AGENT_MODE=""
NAME="" TOKEN="" FROM="" SMTP_USER="" SMTP_PASS="" IMAP_USER="" IMAP_PASS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent)     AGENT_MODE=1; shift ;;
        --name)      NAME="$2"; shift 2 ;;
        --token)     TOKEN="$2"; shift 2 ;;
        --from)      FROM="$2"; shift 2 ;;
        --smtp-user) SMTP_USER="$2"; shift 2 ;;
        --smtp-pass) SMTP_PASS="$2"; shift 2 ;;
        --imap-user) IMAP_USER="$2"; shift 2 ;;
        --imap-pass) IMAP_PASS="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Validate prerequisites ──
if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required" >&2
    exit 1
fi

if [[ ! -f "$AGENTS_JSON" ]]; then
    echo "ERROR: $AGENTS_JSON not found — is fagents-mcp installed?" >&2
    exit 1
fi

# ── Interactive prompts (human mode) ──
if [[ -z "$AGENT_MODE" ]]; then
    echo "Add email credentials for an agent"
    echo ""

    # Show existing agents
    existing=$(jq -r '.agents | keys[]' "$AGENTS_JSON" 2>/dev/null || true)
    if [[ -n "$existing" ]]; then
        echo "Already configured: $existing"
        echo ""
    fi

    [[ -z "$NAME" ]]      && read -rp "Agent name (comms name, e.g. Dev): " NAME
    [[ -z "$TOKEN" ]]     && read -rp "Comms API token: " TOKEN
    [[ -z "$FROM" ]]      && read -rp "From address (e.g. dev@example.com): " FROM
    [[ -z "$SMTP_USER" ]] && read -rp "SMTP username: " SMTP_USER
    [[ -z "$SMTP_PASS" ]] && read -rsp "SMTP password: " SMTP_PASS && echo ""
    [[ -z "$IMAP_USER" ]] && read -rp "IMAP username: " IMAP_USER
    [[ -z "$IMAP_PASS" ]] && read -rsp "IMAP password: " IMAP_PASS && echo ""
fi

# ── Validate inputs ──
for var in NAME TOKEN FROM SMTP_USER SMTP_PASS IMAP_USER IMAP_PASS; do
    if [[ -z "${!var}" ]]; then
        echo "ERROR: --$(echo "$var" | tr '[:upper:]' '[:lower:]' | tr '_' '-') is required" >&2
        exit 1
    fi
done

# ── Check if agent already exists ──
if jq -e --arg name "$NAME" '.agents[$name]' "$AGENTS_JSON" &>/dev/null; then
    if [[ -z "$AGENT_MODE" ]]; then
        read -rp "$NAME already has email configured. Overwrite? [y/N]: " confirm
        [[ "${confirm,,}" =~ ^y ]] || { echo "Aborted."; exit 0; }
    else
        echo "Overwriting existing email config for $NAME"
    fi
fi

# ── Update agents.json ──
tmp=$(mktemp)
jq --arg name "$NAME" \
   --arg token "$TOKEN" \
   --arg from "$FROM" \
   --arg su "$SMTP_USER" \
   --arg sp "$SMTP_PASS" \
   --arg iu "$IMAP_USER" \
   --arg ip "$IMAP_PASS" \
   '.agents[$name] = {"apiKey": $token, "SMTP_FROM": $from, "SMTP_USER": $su, "SMTP_PASS": $sp, "IMAP_USER": $iu, "IMAP_PASS": $ip}' \
   "$AGENTS_JSON" > "$tmp"

mv "$tmp" "$AGENTS_JSON"
chown "$INFRA_USER" "$AGENTS_JSON"
chmod 600 "$AGENTS_JSON"

# ── Restart MCP service ──
if systemctl is-active --quiet fagents-mcp 2>/dev/null; then
    systemctl restart fagents-mcp
    sleep 1
    if systemctl is-active --quiet fagents-mcp; then
        echo "Email configured for $NAME — fagents-mcp restarted"
    else
        echo "WARNING: fagents-mcp failed to restart after update" >&2
        echo "Check: journalctl -u fagents-mcp -n 20" >&2
        exit 1
    fi
else
    echo "Email configured for $NAME — fagents-mcp not running (start with: sudo systemctl start fagents-mcp)"
fi
