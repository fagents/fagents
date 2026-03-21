#!/bin/bash
# add-email.sh — Add email credentials for an agent to fagents-mcp
#
# If fagents-mcp is not installed yet, does first-time setup (clone, build,
# systemd service) via install-email.sh, then adds the agent.
#
# Interactive (human):  sudo bash add-email.sh
# Non-interactive (agent): sudo bash add-email.sh --agent \
#   --name AgentName --token TOKEN --from agent@example.com \
#   --smtp-user user --smtp-pass pass --imap-user user --imap-pass pass \
#   [--smtp-host smtp.example.com] [--imap-host imap.example.com] \
#   [--smtp-port 587] [--imap-port 993] [--mcp-port 9755]
#
# First-time setup also requires: --smtp-host, --imap-host (and optionally
# --smtp-port, --imap-port, --mcp-port). These are stored in agents.json
# and reused for subsequent agents.

set -euo pipefail

INFRA_USER="fagents"
INFRA_HOME=$(eval echo "~$INFRA_USER")
MCP_DIR="$INFRA_HOME/workspace/fagents-mcp"
AGENTS_JSON="$MCP_DIR/agents.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse flags ──
AGENT_MODE=""
NAME="" TOKEN="" FROM="" SMTP_USER="" SMTP_PASS="" IMAP_USER="" IMAP_PASS=""
SMTP_HOST="" SMTP_PORT="" IMAP_HOST="" IMAP_PORT="" MCP_PORT=""
AGENT_USER=""

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
        --smtp-host) SMTP_HOST="$2"; shift 2 ;;
        --smtp-port) SMTP_PORT="$2"; shift 2 ;;
        --imap-host) IMAP_HOST="$2"; shift 2 ;;
        --imap-port) IMAP_PORT="$2"; shift 2 ;;
        --mcp-port)  MCP_PORT="$2"; shift 2 ;;
        --user)      AGENT_USER="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Validate prerequisites ──
if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required" >&2
    exit 1
fi

# ── Detect first-time setup ──
FIRST_TIME=""
if [[ ! -d "$MCP_DIR" ]] || ! systemctl is-enabled --quiet fagents-mcp 2>/dev/null; then
    FIRST_TIME=1
    echo "fagents-mcp not installed — running first-time setup"
    echo ""

    # Need install-email.sh
    INSTALL_EMAIL="$SCRIPT_DIR/install-email.sh"
    if [[ ! -f "$INSTALL_EMAIL" ]]; then
        # Try the fagents repo clone
        INSTALL_EMAIL="$INFRA_HOME/workspace/fagents/install-email.sh"
    fi
    if [[ ! -f "$INSTALL_EMAIL" ]]; then
        echo "ERROR: install-email.sh not found at $SCRIPT_DIR/ or $INFRA_HOME/workspace/fagents/" >&2
        exit 1
    fi

    # Need node
    if ! command -v node &>/dev/null; then
        echo "ERROR: Node.js 18+ is required for fagents-mcp" >&2
        echo "Install with: curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt-get install -y nodejs" >&2
        exit 1
    fi

    # Prompt for shared SMTP/IMAP config (first time only)
    if [[ -z "$AGENT_MODE" ]]; then
        [[ -z "$SMTP_HOST" ]] && read -rp "SMTP host (e.g. smtp.gmail.com): " SMTP_HOST
        [[ -z "$SMTP_PORT" ]] && read -rp "SMTP port [587]: " SMTP_PORT
        [[ -z "$IMAP_HOST" ]] && read -rp "IMAP host (e.g. imap.gmail.com): " IMAP_HOST
        [[ -z "$IMAP_PORT" ]] && read -rp "IMAP port [993]: " IMAP_PORT
        [[ -z "$MCP_PORT" ]]  && read -rp "MCP server port [9755]: " MCP_PORT
    fi

    SMTP_PORT="${SMTP_PORT:-587}"
    IMAP_PORT="${IMAP_PORT:-993}"
    MCP_PORT="${MCP_PORT:-9755}"

    if [[ -z "$SMTP_HOST" || -z "$IMAP_HOST" ]]; then
        echo "ERROR: --smtp-host and --imap-host are required for first-time setup" >&2
        exit 1
    fi
fi

# ── Prompt for agent credentials ──
if [[ -z "$AGENT_MODE" ]]; then
    if [[ -z "$FIRST_TIME" ]]; then
        echo "Add email credentials for an agent"
        echo ""

        # Show existing agents
        existing=$(jq -r '.agents | keys[]' "$AGENTS_JSON" 2>/dev/null || true)
        if [[ -n "$existing" ]]; then
            echo "Already configured: $existing"
            echo ""
        fi
    fi

    [[ -z "$NAME" ]]      && read -rp "Agent name (comms name, e.g. Dev): " NAME
    [[ -z "$TOKEN" ]]     && read -rp "Comms API token: " TOKEN
    [[ -z "$FROM" ]]      && read -rp "From address (e.g. dev@example.com): " FROM
    [[ -z "$SMTP_USER" ]] && read -rp "SMTP username: " SMTP_USER
    [[ -z "$SMTP_PASS" ]] && read -rsp "SMTP password: " SMTP_PASS && echo ""
    [[ -z "$IMAP_USER" ]] && read -rp "IMAP username: " IMAP_USER
    [[ -z "$IMAP_PASS" ]] && read -rsp "IMAP password: " IMAP_PASS && echo ""
    [[ -z "$AGENT_USER" ]] && read -rp "Unix username for this agent (e.g. dev): " AGENT_USER
fi

# ── Validate agent inputs ──
for var in NAME TOKEN FROM SMTP_USER SMTP_PASS IMAP_USER IMAP_PASS; do
    if [[ -z "${!var}" ]]; then
        echo "ERROR: --$(echo "$var" | tr '[:upper:]' '[:lower:]' | tr '_' '-') is required" >&2
        exit 1
    fi
done

# ── Write .mcp.json for the agent ──
write_mcp_json() {
    local mcp_port="$1" token="$2" user="$3"
    [[ -z "$user" ]] && return
    local agent_home
    agent_home=$(eval echo "~$user")
    local ws_dir="$agent_home/workspace/$user"
    local mcp_file="$ws_dir/.mcp.json"
    [[ -d "$ws_dir" ]] || return

    local mcp_url="http://127.0.0.1:${mcp_port}/mcp"
    if [[ -f "$mcp_file" ]]; then
        local tmp
        tmp=$(jq --arg url "$mcp_url" --arg key "$token" \
            '.mcpServers["fagents-mcp"] = {"type": "http", "url": $url, "headers": {"x-api-key": $key}}' \
            "$mcp_file")
        echo "$tmp" > "$mcp_file"
    else
        jq -n --arg url "$mcp_url" --arg key "$token" \
            '{mcpServers: {"fagents-mcp": {"type": "http", "url": $url, "headers": {"x-api-key": $key}}}}' \
            > "$mcp_file"
    fi
    chown "$user:fagent" "$mcp_file"
    chmod 600 "$mcp_file"
    echo "  .mcp.json written for $user"
}

# ── First-time: run install-email.sh ──
if [[ -n "$FIRST_TIME" ]]; then
    echo ""
    SMTP_HOST="$SMTP_HOST" \
    SMTP_PORT="$SMTP_PORT" \
    IMAP_HOST="$IMAP_HOST" \
    IMAP_PORT="$IMAP_PORT" \
    bash "$INSTALL_EMAIL" \
        --port "$MCP_PORT" \
        --dir "$MCP_DIR" \
        --user "$INFRA_USER" \
        --agent "$NAME:$TOKEN:$FROM:$SMTP_USER:$SMTP_PASS:$IMAP_USER:$IMAP_PASS:$AGENT_USER"

    # Create #email-log channel for gate_email audit trail
    _comms_url="http://127.0.0.1:9754"
    curl -sf -X POST "$_comms_url/api/channels/email-log/messages" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"message": "Email audit log initialized."}' > /dev/null 2>&1 || true

    write_mcp_json "$MCP_PORT" "$TOKEN" "$AGENT_USER"
    echo "Email configured for $NAME"
    exit 0
fi

# ── Existing install: write email.env to .agents/ ──

AGENTS_DIR="$INFRA_HOME/.agents"

# Resolve unix username
if [[ -z "$AGENT_USER" ]]; then
    echo "ERROR: --user <unix-username> is required" >&2
    exit 1
fi

# Read shared SMTP/IMAP config if not provided (from existing email.env files)
if [[ -z "$SMTP_HOST" || -z "$IMAP_HOST" ]]; then
    # Try to read from an existing agent's email.env
    _existing_env=$(find "$AGENTS_DIR" -name email.env -print -quit 2>/dev/null)
    if [[ -n "$_existing_env" ]]; then
        [[ -z "$SMTP_HOST" ]] && SMTP_HOST=$(grep '^SMTP_HOST=' "$_existing_env" | cut -d= -f2-)
        [[ -z "$SMTP_PORT" ]] && SMTP_PORT=$(grep '^SMTP_PORT=' "$_existing_env" | cut -d= -f2-)
        [[ -z "$IMAP_HOST" ]] && IMAP_HOST=$(grep '^IMAP_HOST=' "$_existing_env" | cut -d= -f2-)
        [[ -z "$IMAP_PORT" ]] && IMAP_PORT=$(grep '^IMAP_PORT=' "$_existing_env" | cut -d= -f2-)
    fi
    # Still missing? Ask interactively
    if [[ -z "$SMTP_HOST" && -z "$AGENT_MODE" ]]; then
        read -rp "SMTP host (e.g. smtp.gmail.com): " SMTP_HOST
        [[ -z "$SMTP_PORT" ]] && read -rp "SMTP port [587]: " SMTP_PORT
        read -rp "IMAP host (e.g. imap.gmail.com): " IMAP_HOST
        [[ -z "$IMAP_PORT" ]] && read -rp "IMAP port [993]: " IMAP_PORT
    fi
fi
SMTP_PORT="${SMTP_PORT:-587}"
IMAP_PORT="${IMAP_PORT:-993}"

if [[ -z "$SMTP_HOST" || -z "$IMAP_HOST" ]]; then
    echo "ERROR: SMTP_HOST and IMAP_HOST are required (use --smtp-host, --imap-host)" >&2
    exit 1
fi

# Check if agent already has email.env
EMAIL_ENV="$AGENTS_DIR/$AGENT_USER/email.env"
if [[ -f "$EMAIL_ENV" ]]; then
    if [[ -z "$AGENT_MODE" ]]; then
        read -rp "$NAME already has email configured. Overwrite? [y/N]: " confirm
        [[ "${confirm,,}" =~ ^y ]] || { echo "Aborted."; exit 0; }
    else
        echo "Overwriting existing email config for $NAME"
    fi
fi

mkdir -p "$AGENTS_DIR/$AGENT_USER"
cat > "$EMAIL_ENV" << EMAILEOF
MCP_API_KEY=$TOKEN
SMTP_HOST=$SMTP_HOST
SMTP_PORT=$SMTP_PORT
SMTP_FROM=$FROM
SMTP_USER=$SMTP_USER
SMTP_PASS=$SMTP_PASS
IMAP_HOST=$IMAP_HOST
IMAP_PORT=$IMAP_PORT
IMAP_USER=$IMAP_USER
IMAP_PASS=$IMAP_PASS
EMAILEOF
chown "$INFRA_USER:fagent" "$EMAIL_ENV"
chmod 600 "$EMAIL_ENV"

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

# ── Write .mcp.json for the agent ──
_mcp_port=$(grep -oP 'MCP_PORT=\K\d+' "$MCP_DIR/.env" 2>/dev/null || echo "9755")
write_mcp_json "$_mcp_port" "$TOKEN" "$AGENT_USER"
