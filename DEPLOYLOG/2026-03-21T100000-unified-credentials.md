# Unified Credentials — Deploy to Existing Installation

**Date:** 2026-03-21
**Repos changed:** fagents-mcp, fagents

## Commits to pull

```
fagents-mcp:  b4d5706118ee6c7af9ea89c98c6ffd96edfae1be  Unify credentials: read email config from .agents/ instead of agents.json
fagents:      20594b431a575c1013b41839b14ed00870b69676  Unify credentials: installer writes email.env to .agents/
```

New installs get this automatically. This doc is for existing deployments.

## What changed

Email credentials move from `agents.json` (in the fagents-mcp directory) to per-agent `email.env` files in `/home/fagents/.agents/<username>/` — the same location as Telegram, X, and OpenAI credentials. One credential store, one format, one permission model.

- **fagents-mcp** — reads from `.agents/<user>/email.env` instead of `agents.json`. Uses `AGENTS_DIR` env var to find the directory.
- **fagents** — `add-email.sh` and `install-email.sh` write to `.agents/` instead of `agents.json`.

## Prerequisites

None. The `.agents/` directory already exists on all installs.

## Setup steps

All commands run as root on the fagents host.

```bash
INFRA_USER="fagents"
INFRA_HOME=$(eval echo "~$INFRA_USER")
MCP_DIR="$INFRA_HOME/workspace/fagents-mcp"
AGENTS_DIR="$INFRA_HOME/.agents"
```

### 1. Pull repos

```bash
for repo in fagents-mcp fagents; do
    sudo git -C "$INFRA_HOME/repos/${repo}.git" fetch "https://github.com/fagents/${repo}.git" main:main
    sudo git -C "$INFRA_HOME/workspace/${repo}" pull
done
```

### 2. Rebuild fagents-mcp

```bash
sudo -u "$INFRA_USER" bash -c "cd '$MCP_DIR' && npm install && npm run build"
```

### 3. Migrate agents.json to email.env files

```bash
AGENTS_JSON="$MCP_DIR/agents.json"

if [ ! -f "$AGENTS_JSON" ]; then
    echo "No agents.json found — email may not be configured. Skipping migration."
else
    # Read shared config
    SMTP_HOST=$(jq -r '.shared.SMTP_HOST // empty' "$AGENTS_JSON")
    SMTP_PORT=$(jq -r '.shared.SMTP_PORT // "587"' "$AGENTS_JSON")
    IMAP_HOST=$(jq -r '.shared.IMAP_HOST // empty' "$AGENTS_JSON")
    IMAP_PORT=$(jq -r '.shared.IMAP_PORT // "993"' "$AGENTS_JSON")

    # Per-agent: resolve unix username from token, write email.env
    for agent in $(jq -r '.agents | keys[]' "$AGENTS_JSON"); do
        token=$(jq -r --arg a "$agent" '.agents[$a].apiKey' "$AGENTS_JSON")

        # Find unix username by matching token in start-agent.sh
        username=""
        for user_dir in "$AGENTS_DIR"/*/; do
            [ -d "$user_dir" ] || continue
            user=$(basename "$user_dir")
            ws=$(eval echo "~$user")/workspace/$user
            if grep -q "$token" "$ws/start-agent.sh" 2>/dev/null; then
                username="$user"
                break
            fi
        done

        if [ -z "$username" ]; then
            echo "WARNING: could not resolve unix user for agent '$agent' — skipping"
            continue
        fi

        mkdir -p "$AGENTS_DIR/$username"
        {
            echo "MCP_API_KEY=$token"
            echo "SMTP_HOST=$SMTP_HOST"
            echo "SMTP_PORT=$SMTP_PORT"
            jq -r --arg a "$agent" '.agents[$a] | to_entries[] | select(.key != "apiKey") | "\(.key)=\(.value)"' "$AGENTS_JSON"
            echo "IMAP_HOST=$IMAP_HOST"
            echo "IMAP_PORT=$IMAP_PORT"
        } > "$AGENTS_DIR/$username/email.env"
        chown "$INFRA_USER:fagent" "$AGENTS_DIR/$username/email.env"
        chmod 600 "$AGENTS_DIR/$username/email.env"
        echo "$username ($agent): email.env created"
    done

    # Back up agents.json
    mv "$AGENTS_JSON" "$AGENTS_JSON.bak"
    echo "agents.json backed up to agents.json.bak"
fi
```

### 4. Add AGENTS_DIR to MCP .env

```bash
MCP_ENV="$MCP_DIR/.env"
if ! grep -q 'AGENTS_DIR' "$MCP_ENV" 2>/dev/null; then
    echo "AGENTS_DIR=$AGENTS_DIR" >> "$MCP_ENV"
    chown "$INFRA_USER" "$MCP_ENV"
    echo "AGENTS_DIR added to MCP .env"
fi
```

### 5. Restart MCP service

```bash
sudo systemctl restart fagents-mcp
```

## Doctor

```bash
INFRA_USER="fagents"
INFRA_HOME=$(eval echo "~$INFRA_USER")
MCP_DIR="$INFRA_HOME/workspace/fagents-mcp"
AGENTS_DIR="$INFRA_HOME/.agents"

echo "=== agents.json ==="
test ! -f "$MCP_DIR/agents.json" && echo "ok: agents.json removed (backed up)" || echo "WARN: agents.json still present"

echo ""
echo "=== email.env files ==="
for dir in "$AGENTS_DIR"/*/; do
    [ -d "$dir" ] || continue
    user=$(basename "$dir")
    if [ -f "$dir/email.env" ]; then
        echo "ok: $user has email.env"
    fi
done

echo ""
echo "=== AGENTS_DIR in .env ==="
grep -q 'AGENTS_DIR' "$MCP_DIR/.env" && echo "ok: AGENTS_DIR set" || echo "FAIL: AGENTS_DIR missing from .env"

echo ""
echo "=== MCP service ==="
systemctl is-active --quiet fagents-mcp && echo "ok: fagents-mcp running" || echo "FAIL: fagents-mcp not running"

echo ""
echo "=== MCP health ==="
_port=$(grep 'MCP_PORT' "$MCP_DIR/.env" 2>/dev/null | cut -d= -f2 || echo "9755")
curl -sf --max-time 5 "http://127.0.0.1:${_port}/health" > /dev/null && echo "ok: MCP healthy" || echo "FAIL: MCP not responding"
```

## How it works

Before: MCP server reads `agents.json` at startup — one JSON file with all agents + shared SMTP/IMAP config.

After: MCP server scans `.agents/<user>/email.env` files at startup. Each file has the full config for that agent (API key, SMTP host/port/from/user/pass, IMAP host/port/user/pass). Same location as Telegram, X, and OpenAI credentials.

## Cleanup

To revert:
```bash
# Restore agents.json
mv "$MCP_DIR/agents.json.bak" "$MCP_DIR/agents.json"
# Remove AGENTS_DIR from .env
sed -i '/AGENTS_DIR/d' "$MCP_DIR/.env"
# Restart MCP
sudo systemctl restart fagents-mcp
# Note: email.env files can stay — they don't interfere with agents.json
```
