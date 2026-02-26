#!/bin/bash
# install-email.sh — Set up fagents-mcp email server for a team
#
# Installs fagents-mcp, configures SMTP/IMAP, generates agents.json,
# and creates a systemd service.
#
# Usage (called by install-team.sh):
#   install-email.sh --port PORT --dir DIR --user USER \
#     --agent "name:token:from" [--agent ...]
#
# SMTP/IMAP config via environment variables:
#   SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS
#   IMAP_HOST, IMAP_PORT, IMAP_USER, IMAP_PASS
#
# Prerequisites: node (>= 18), npm, git

set -euo pipefail

MCP_REPO="https://github.com/fagents/fagents-mcp.git"
EMAIL_PORT=""
INSTALL_DIR=""
SERVICE_USER=""
AGENT_SPECS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)  EMAIL_PORT="$2"; shift 2 ;;
        --dir)   INSTALL_DIR="$2"; shift 2 ;;
        --user)  SERVICE_USER="$2"; shift 2 ;;
        --agent) AGENT_SPECS+=("$2"); shift 2 ;;
        *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Validate ──
[[ -z "$EMAIL_PORT" ]]    && { echo "ERROR: --port required" >&2; exit 1; }
[[ -z "$INSTALL_DIR" ]]   && { echo "ERROR: --dir required" >&2; exit 1; }
[[ -z "$SERVICE_USER" ]]  && { echo "ERROR: --user required" >&2; exit 1; }
[[ ${#AGENT_SPECS[@]} -eq 0 ]] && { echo "ERROR: at least one --agent required" >&2; exit 1; }
[[ -z "${SMTP_HOST:-}" ]] && { echo "ERROR: SMTP_HOST not set" >&2; exit 1; }
[[ -z "${SMTP_USER:-}" ]] && { echo "ERROR: SMTP_USER not set" >&2; exit 1; }
[[ -z "${SMTP_PASS:-}" ]] && { echo "ERROR: SMTP_PASS not set" >&2; exit 1; }
[[ -z "${IMAP_HOST:-}" ]] && { echo "ERROR: IMAP_HOST not set" >&2; exit 1; }
[[ -z "${IMAP_USER:-}" ]] && { echo "ERROR: IMAP_USER not set" >&2; exit 1; }
[[ -z "${IMAP_PASS:-}" ]] && { echo "ERROR: IMAP_PASS not set" >&2; exit 1; }

# Check for node
if ! command -v node &>/dev/null; then
    echo "ERROR: node is required but not found. Install Node.js 18+ first." >&2
    exit 1
fi
NODE_VERSION=$(node -v | sed 's/v//' | cut -d. -f1)
if [[ "$NODE_VERSION" -lt 18 ]]; then
    echo "ERROR: Node.js 18+ required (found v$NODE_VERSION)" >&2
    exit 1
fi

echo "  Setting up email MCP server..."

# ── Clone or update fagents-mcp ──
if [[ -d "$INSTALL_DIR/.git" ]]; then
    echo "  fagents-mcp already at $INSTALL_DIR — pulling latest..."
    su - "$SERVICE_USER" -c "cd '$INSTALL_DIR' && git pull --quiet" 2>/dev/null || true
else
    echo "  Cloning fagents-mcp..."
    su - "$SERVICE_USER" -c "git clone '$MCP_REPO' '$INSTALL_DIR'" 2>&1 | tail -1
fi

# ── Install dependencies and build ──
echo "  Installing dependencies..."
su - "$SERVICE_USER" -c "cd '$INSTALL_DIR' && npm install 2>&1 | tail -1"

echo "  Building..."
su - "$SERVICE_USER" -c "cd '$INSTALL_DIR' && npm run build 2>&1 | tail -1"

# ── Generate .env ──
cat > "$INSTALL_DIR/.env" << EOF
MCP_PORT=$EMAIL_PORT
EOF
chown "$SERVICE_USER" "$INSTALL_DIR/.env"
chmod 600 "$INSTALL_DIR/.env"

# ── Generate agents.json ──
# Build JSON with jq: shared SMTP/IMAP config + per-agent apiKey + SMTP_FROM
agents_obj='{}'
for spec in "${AGENT_SPECS[@]}"; do
    IFS=':' read -r name token from_addr <<< "$spec"
    agents_obj=$(echo "$agents_obj" | jq \
        --arg name "$name" \
        --arg token "$token" \
        --arg from "$from_addr" \
        '.[$name] = {"apiKey": $token, "SMTP_FROM": $from}')
done

jq -n \
    --argjson agents "$agents_obj" \
    --arg smtp_host "$SMTP_HOST" \
    --arg smtp_port "${SMTP_PORT:-587}" \
    --arg smtp_user "$SMTP_USER" \
    --arg smtp_pass "$SMTP_PASS" \
    --arg imap_host "$IMAP_HOST" \
    --arg imap_port "${IMAP_PORT:-993}" \
    --arg imap_user "$IMAP_USER" \
    --arg imap_pass "$IMAP_PASS" \
    '{
        agents: $agents,
        shared: {
            SMTP_HOST: $smtp_host,
            SMTP_PORT: $smtp_port,
            SMTP_USER: $smtp_user,
            SMTP_PASS: $smtp_pass,
            IMAP_HOST: $imap_host,
            IMAP_PORT: $imap_port,
            IMAP_USER: $imap_user,
            IMAP_PASS: $imap_pass
        }
    }' > "$INSTALL_DIR/agents.json"

chown "$SERVICE_USER" "$INSTALL_DIR/agents.json"
chmod 600 "$INSTALL_DIR/agents.json"

# ── Create systemd service ──
SERVICE_NAME="fagents-mcp"
NODE_BIN=$(command -v node)

cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=fagents-mcp — email MCP server
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$NODE_BIN dist/server.js
Restart=on-failure
RestartSec=10
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" --quiet 2>/dev/null
systemctl restart "$SERVICE_NAME"

# Wait for it to come up and verify MCP endpoint works
# Extract first agent's API key for the MCP endpoint test
TEST_KEY=$(jq -r '.agents | to_entries[0].value.apiKey' "$INSTALL_DIR/agents.json")

verify_mcp() {
    # Check /health first (basic HTTP)
    curl -sf "http://127.0.0.1:$EMAIL_PORT/health" > /dev/null 2>&1 || return 1
    # Then verify /mcp actually handles requests (catches stale process issues)
    local resp
    resp=$(curl -sf -X POST "http://127.0.0.1:$EMAIL_PORT/mcp" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -H "x-api-key: $TEST_KEY" \
        -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"install-verify","version":"1.0"}},"id":1}' 2>/dev/null)
    echo "$resp" | grep -q '"protocolVersion"' 2>/dev/null
}

MCP_OK=""
for i in 1 2 3 4 5; do
    sleep 1
    if verify_mcp; then
        MCP_OK=1
        break
    fi
done

if [[ -z "$MCP_OK" ]]; then
    echo "  MCP endpoint not responding — restarting service..."
    systemctl restart "$SERVICE_NAME"
    for i in 1 2 3 4 5; do
        sleep 1
        if verify_mcp; then
            MCP_OK=1
            break
        fi
    done
fi

if [[ -n "$MCP_OK" ]]; then
    echo "  Email MCP server running on port $EMAIL_PORT (verified)"
else
    echo "  WARNING: Email MCP server may not have started correctly."
    echo "  Check: journalctl -u $SERVICE_NAME -n 20"
fi
