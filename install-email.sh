#!/bin/bash
# install-email.sh — Set up fagents-mcp email server for a team
#
# Installs fagents-mcp, configures SMTP/IMAP, writes per-agent email.env
# files to .agents/, and creates a systemd service.
#
# Usage (called by install-team.sh):
#   install-email.sh --port PORT --dir DIR --user USER \
#     --agent "name:token:from:smtp_user:smtp_pass:imap_user:imap_pass:unix_user" [--agent ...]
#
# SMTP/IMAP host/port via environment variables (shared across agents):
#   SMTP_HOST, SMTP_PORT, IMAP_HOST, IMAP_PORT
#
# Credentials are per-agent (in --agent spec). Passwords cannot contain ':'.
# SMTP_FROM, SMTP_USER, SMTP_PASS, IMAP_USER, IMAP_PASS are per-agent.
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
[[ -z "${IMAP_HOST:-}" ]] && { echo "ERROR: IMAP_HOST not set" >&2; exit 1; }

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

# ── Clone fagents-mcp (bare repo + working copy, same pattern as other repos) ──
REPOS_DIR="$(eval echo "~$SERVICE_USER")/repos"
BARE_REPO="$REPOS_DIR/fagents-mcp.git"
su - "$SERVICE_USER" -c "mkdir -p ~/repos"

if [[ -d "$BARE_REPO" ]]; then
    echo "  fagents-mcp.git already exists — fetching latest..."
    su - "$SERVICE_USER" -c "git -C ~/repos/fagents-mcp.git fetch '$MCP_REPO' main:main" 2>/dev/null || true
else
    echo "  Cloning fagents-mcp bare repo..."
    su - "$SERVICE_USER" -c "git clone --bare '$MCP_REPO' ~/repos/fagents-mcp.git" 2>&1 | tail -1
    su - "$SERVICE_USER" -c "git -C ~/repos/fagents-mcp.git remote remove origin" 2>/dev/null || true
fi

if [[ -d "$INSTALL_DIR/.git" ]]; then
    echo "  fagents-mcp working copy exists — pulling..."
    su - "$SERVICE_USER" -c "cd '$INSTALL_DIR' && git pull --quiet" 2>/dev/null || true
else
    echo "  Cloning fagents-mcp working copy..."
    su - "$SERVICE_USER" -c "git clone ~/repos/fagents-mcp.git '$INSTALL_DIR'" 2>&1 | tail -1
fi

# ── Install dependencies and build ──
echo "  Installing dependencies..."
su - "$SERVICE_USER" -c "cd '$INSTALL_DIR' && npm install" > /dev/null 2>&1

echo "  Building..."
su - "$SERVICE_USER" -c "cd '$INSTALL_DIR' && npm run build" > /dev/null 2>&1

# ── Generate .env ──
cat > "$INSTALL_DIR/.env" << EOF
MCP_PORT=$EMAIL_PORT
AGENTS_DIR=$(eval echo "~$SERVICE_USER")/.agents
EOF
chown "$SERVICE_USER" "$INSTALL_DIR/.env"
chmod 600 "$INSTALL_DIR/.env"

# ── Generate email.env files in .agents/ ──
# Spec format: name:token:from:smtp_user:smtp_pass:imap_user:imap_pass:unix_user
# Note: ':' in passwords is not supported.
AGENTS_DIR="$(eval echo "~$SERVICE_USER")/.agents"
mkdir -p "$AGENTS_DIR"

_first_token=""
for spec in "${AGENT_SPECS[@]}"; do
    IFS=':' read -r name token from_addr smtp_user smtp_pass imap_user imap_pass unix_user <<< "$spec"
    [[ -z "$smtp_user" ]] && { echo "ERROR: no smtp_user for agent '$name'" >&2; exit 1; }
    [[ -z "$smtp_pass" ]] && { echo "ERROR: no smtp_pass for agent '$name'" >&2; exit 1; }
    [[ -z "$imap_user" ]] && { echo "ERROR: no imap_user for agent '$name'" >&2; exit 1; }
    [[ -z "$imap_pass" ]] && { echo "ERROR: no imap_pass for agent '$name'" >&2; exit 1; }
    [[ -z "$unix_user" ]] && { echo "ERROR: no unix_user for agent '$name'" >&2; exit 1; }

    mkdir -p "$AGENTS_DIR/$unix_user"
    cat > "$AGENTS_DIR/$unix_user/email.env" << EMAILEOF
MCP_API_KEY=$token
SMTP_HOST=$SMTP_HOST
SMTP_PORT=${SMTP_PORT:-587}
SMTP_FROM=$from_addr
SMTP_USER=$smtp_user
SMTP_PASS=$smtp_pass
IMAP_HOST=$IMAP_HOST
IMAP_PORT=${IMAP_PORT:-993}
IMAP_USER=$imap_user
IMAP_PASS=$imap_pass
EMAILEOF
    chown "$SERVICE_USER:fagent" "$AGENTS_DIR/$unix_user/email.env"
    chmod 600 "$AGENTS_DIR/$unix_user/email.env"
    echo "  $name ($unix_user): email.env written"

    [[ -z "$_first_token" ]] && _first_token="$token"
done

# ── Create service (systemd on Linux, launchd on macOS) ──
SERVICE_NAME="fagents-mcp"
NODE_BIN=$(command -v node)

if [[ "$(uname)" == "Darwin" ]]; then
    # macOS: launchd plist
    PLIST="/Library/LaunchDaemons/ai.fagents-mcp.plist"
    cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>ai.fagents-mcp</string>
    <key>UserName</key>
    <string>$SERVICE_USER</string>
    <key>WorkingDirectory</key>
    <string>$INSTALL_DIR</string>
    <key>ProgramArguments</key>
    <array>
        <string>$NODE_BIN</string>
        <string>dist/server.js</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$INSTALL_DIR/fagents-mcp.log</string>
    <key>StandardErrorPath</key>
    <string>$INSTALL_DIR/fagents-mcp.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>NODE_ENV</key>
        <string>production</string>
    </dict>
</dict>
</plist>
EOF
    chmod 644 "$PLIST"
    launchctl bootout system/ai.fagents-mcp 2>/dev/null || true
    launchctl bootstrap system "$PLIST"
else
    # Linux: systemd service
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
fi

# Wait for it to come up and verify MCP endpoint works
# Extract first agent's API key for the MCP endpoint test
TEST_KEY="$_first_token"

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
    if [[ "$(uname)" == "Darwin" ]]; then
        launchctl kickstart -k system/ai.fagents-mcp
    else
        systemctl restart "$SERVICE_NAME"
    fi
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
    if [[ "$(uname)" == "Darwin" ]]; then
        echo "  Check: cat $INSTALL_DIR/fagents-mcp.log"
    else
        echo "  Check: journalctl -u $SERVICE_NAME -n 20"
    fi
fi
