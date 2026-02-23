#!/bin/bash
# install-team.sh — Provision a team of agents on one machine (colocated mode)
#
# Usage: sudo ./install-team.sh [options] [AGENT1 AGENT2 ...]
#    or: sudo ./install-team.sh --template business
#
# Each AGENT can be NAME or NAME:WORKSPACE
#   NAME only:       workspace defaults to <name lowercase>
#   NAME:WORKSPACE:  explicit workspace name
#
# Options:
#   --template NAME         Use a team template (e.g., business)
#   --comms-port PORT       Comms server port (default: 9754)
#   --comms-repo URL        fagents-comms git repo URL (default: GitHub)
#   --mcp-port PORT         MCP local port (enables MCP for all agents)
#   --skip-claude-auth             Skip Claude Code authentication setup
#
# Creates a 'fagents' infra user that owns the comms server and git repos.
# Agents connect via localhost. Easy to migrate to remote server later.
#
# Example:
#   sudo ./install-team.sh --template business
#   sudo ./install-team.sh --comms-repo URL COO Dev Ops
#
# Prerequisites: git, python3, curl, jq

set -euo pipefail

# ── Defaults ──
COMMS_PORT=9754
COMMS_REPO="https://github.com/fagents/fagents-comms.git"
MCP_PORT=""
SKIP_CLAUDE_AUTH=""
TEMPLATE=""
AGENTS=()
HUMAN_NAME=""
INFRA_USER="fagents"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTONOMY_REPO="https://github.com/fagents/fagents-autonomy.git"

# ── Parse args ──
while [[ $# -gt 0 ]]; do
    case "$1" in
        --template)     TEMPLATE="$2"; shift 2 ;;
        --comms-port)   COMMS_PORT="$2"; shift 2 ;;
        --comms-repo)   COMMS_REPO="$2"; shift 2 ;;
        --mcp-port)     MCP_PORT="$2"; shift 2 ;;
        --skip-claude-auth)    SKIP_CLAUDE_AUTH=1; shift ;;
        --help|-h)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)  AGENTS+=("$1"); shift ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must run as root (sudo)." >&2
    exit 1
fi

# ── Load template if specified ──
TEMPLATE_DIR=""
declare -A AGENT_SOULS
declare -A AGENT_BOOTSTRAP

load_template() {
    local tdir="$1"
    if [[ ! -f "$tdir/team.json" ]]; then
        echo "ERROR: Template not found at $tdir/team.json" >&2
        exit 1
    fi
    while IFS= read -r line; do
        name=$(echo "$line" | jq -r '.name')
        [[ -z "$name" || "$name" == "null" ]] && continue
        soul=$(echo "$line" | jq -r '.soul // empty')
        is_bootstrap=$(echo "$line" | jq -r '.bootstrap // false')
        AGENTS+=("$name")
        [[ -n "$soul" ]] && AGENT_SOULS["$name"]="$soul"
        [[ "$is_bootstrap" == "true" ]] && AGENT_BOOTSTRAP["$name"]=1
    done < <(jq -c '.agents[]' "$tdir/team.json")
}

if [[ -n "$TEMPLATE" ]]; then
    TEMPLATE_DIR="$SCRIPT_DIR/templates/$TEMPLATE"
    load_template "$TEMPLATE_DIR"
fi

# ── Interactive mode ──
prompt() {
    local var="$1" prompt_text="$2" default="$3"
    if [[ -n "$default" ]]; then
        read -rp "$prompt_text [$default]: " val
        eval "$var='${val:-$default}'"
    else
        read -rp "$prompt_text: " val
        eval "$var='$val'"
    fi
}

if [[ ${#AGENTS[@]} -eq 0 ]]; then
    echo "=== Freeturtle Team Install (interactive) ==="
    echo ""
    echo "No agents specified and no template selected."
    echo "Available templates:"
    for t in "$SCRIPT_DIR"/templates/*/team.json; do
        tname=$(basename "$(dirname "$t")")
        tdesc=$(jq -r '.description // "no description"' "$t")
        echo "  $tname — $tdesc"
    done
    echo ""
    prompt TEMPLATE "Choose a template (or 'none' for manual)" "business"
    if [[ "$TEMPLATE" != "none" ]]; then
        TEMPLATE_DIR="$SCRIPT_DIR/templates/$TEMPLATE"
        load_template "$TEMPLATE_DIR"
    else
        echo "Enter agent names separated by spaces:"
        read -rp "> " agent_input
        for a in $agent_input; do AGENTS+=("$a"); done
    fi
fi

if [[ ${#AGENTS[@]} -eq 0 ]]; then
    echo "ERROR: No agents specified." >&2
    exit 1
fi

# ── Name agents (template roles → personal names) ──
if [[ -n "$TEMPLATE_DIR" && -z "${NONINTERACTIVE:-}" ]]; then
    echo ""
    echo "Name your agents (Enter to keep default):"
    RENAMED_AGENTS=()
    for name in "${AGENTS[@]}"; do
        read -rp "  $name → name: [$name] " new_name
        new_name="${new_name:-$name}"
        if [[ "$new_name" != "$name" ]]; then
            [[ -n "${AGENT_SOULS[$name]:-}" ]] && AGENT_SOULS["$new_name"]="${AGENT_SOULS[$name]}" && unset "AGENT_SOULS[$name]"
            [[ -n "${AGENT_BOOTSTRAP[$name]:-}" ]] && AGENT_BOOTSTRAP["$new_name"]=1 && unset "AGENT_BOOTSTRAP[$name]"
        fi
        RENAMED_AGENTS+=("$new_name")
    done
    AGENTS=("${RENAMED_AGENTS[@]}")
fi

# ── Interactive confirmation ──
echo ""
echo "Agents: ${AGENTS[*]}"
prompt COMMS_PORT "Comms server port" "$COMMS_PORT"

# Ask for human name
echo ""
echo "A human account is needed to access the web UI and send messages."
prompt HUMAN_NAME "Your name" ""
if [[ -z "$HUMAN_NAME" ]]; then
    echo "ERROR: Human name is required." >&2
    exit 1
fi

echo ""
echo "  Infra user:  $INFRA_USER (owns comms + git repos)"
echo "  Agents:      ${AGENTS[*]}"
echo "  Human:       $HUMAN_NAME"
echo "  Comms:       127.0.0.1:$COMMS_PORT"

# Warn about sudo agents
for name in "${AGENTS[@]}"; do
    if [[ -n "${AGENT_BOOTSTRAP[$name]:-}" ]]; then
        echo ""
        echo "  WARNING: $name WILL HAVE SUDO. It can break your system. Mistakes will happen."
    fi
done

echo ""
read -rp "Proceed? [Y/n] " confirm
if [[ "${confirm,,}" == "n" ]]; then
    echo "Aborted."
    exit 0
fi

# ── Parse AGENT:WORKSPACE pairs ──
declare -A AGENT_WORKSPACES
AGENT_NAMES=()
for spec in "${AGENTS[@]}"; do
    name="${spec%%:*}"
    if [[ "$spec" == *":"* ]]; then
        ws="${spec#*:}"
    else
        ws="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
    fi
    AGENT_NAMES+=("$name")
    AGENT_WORKSPACES["$name"]="$ws"
done

agent_user() {
    echo "$(echo "$1" | tr '[:upper:]' '[:lower:]')"
}

# ── Step 1: Create group and users ──
echo ""
echo "=== Step 1: Create users ==="
groupadd -f fagent

# Create infra user
if id "$INFRA_USER" &>/dev/null; then
    echo "  $INFRA_USER (infra) already exists"
else
    useradd -m -g fagent -s /bin/bash "$INFRA_USER"
    echo "  Created $INFRA_USER (infra)"
fi
INFRA_HOME=$(eval echo "~$INFRA_USER")

# Create agent users
for name in "${AGENT_NAMES[@]}"; do
    user=$(agent_user "$name")
    if id "$user" &>/dev/null; then
        echo "  $user already exists"
    else
        useradd -m -g fagent -s /bin/bash "$user"
        echo "  Created $user"
    fi
    # Grant sudo to bootstrap/ops agent
    if [[ -n "${AGENT_BOOTSTRAP[$name]:-}" ]]; then
        if [[ ! -f "/etc/sudoers.d/$user" ]]; then
            echo "$user ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/$user"
            chmod 440 "/etc/sudoers.d/$user"
            echo "  Granted sudo to $user (bootstrap/ops)"
        fi
    fi
done
echo ""

# ── Step 2: Set up infra (comms + git repos) ──
echo "=== Step 2: Infrastructure (under $INFRA_USER) ==="
REPOS_DIR="$INFRA_HOME/repos"
su - "$INFRA_USER" -c "mkdir -p ~/repos"

# Clone fagents-comms (shared copy, detached from GitHub)
COMMS_DIR="$INFRA_HOME/repos/fagents-comms"
if [[ -d "$COMMS_DIR" ]]; then
    echo "  fagents-comms already at $COMMS_DIR"
else
    su - "$INFRA_USER" -c "git clone '$COMMS_REPO' ~/repos/fagents-comms && git -C ~/repos/fagents-comms remote remove origin" 2>&1 | sed 's/^/  /'
fi

# Clone fagents-autonomy as bare repo (shared, detached from GitHub)
# Bare repos avoid git's "dubious ownership" check across users
SHARED_AUTONOMY="$INFRA_HOME/repos/fagents-autonomy.git"
if [[ -d "$SHARED_AUTONOMY" ]]; then
    echo "  fagents-autonomy already at $SHARED_AUTONOMY"
else
    su - "$INFRA_USER" -c "git clone --bare '$AUTONOMY_REPO' ~/repos/fagents-autonomy.git && git -C ~/repos/fagents-autonomy.git remote remove origin 2>/dev/null; true" 2>&1 | sed 's/^/  /'
fi
# Make readable so agents can clone from it
chmod -R g+rX "$SHARED_AUTONOMY"
# Agents now clone from the local shared copy
AUTONOMY_REPO="$SHARED_AUTONOMY"

# Create bare git repos for each agent
for name in "${AGENT_NAMES[@]}"; do
    ws="${AGENT_WORKSPACES[$name]}"
    repo_path="$REPOS_DIR/$ws.git"
    if [[ -d "$repo_path" ]]; then
        echo "  Repo $ws.git already exists"
    else
        su - "$INFRA_USER" -c "git init --bare -b main ~/repos/$ws.git" 2>&1 | sed 's/^/  /'
        echo "  Created bare repo: $ws.git"
    fi
done
# Make repos group-readable so agents can push/pull
chmod -R g+rX "$REPOS_DIR"
echo ""

# ── Step 3: Start comms server ──
echo "=== Step 3: Start comms server ==="
if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$COMMS_PORT/api/health" 2>/dev/null | grep -q "200"; then
    echo "  Comms server already running on port $COMMS_PORT"
else
    echo "  Starting comms server on port $COMMS_PORT..."
    su - "$INFRA_USER" -c "cd ~/repos/fagents-comms && nohup python3 server.py serve --port $COMMS_PORT > comms.log 2>&1 &"
    for i in 1 2 3 4 5; do
        sleep 1
        if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$COMMS_PORT/api/health" 2>/dev/null | grep -q "200"; then
            echo "  Comms server running"
            break
        fi
        if [[ $i -eq 5 ]]; then
            echo "  WARNING: Comms server may not have started. Check $COMMS_DIR/comms.log"
        fi
    done
fi

# Create general channel
su - "$INFRA_USER" -c "cd ~/repos/fagents-comms && python3 server.py create-channel general 2>/dev/null" || true
echo ""

# ── Step 4: Register agents + human with comms ──
echo "=== Step 4: Register agents + human ==="
declare -A AGENT_TOKENS

# Register via CLI (writes tokens.json directly)
for name in "${AGENT_NAMES[@]}"; do
    output=$(su - "$INFRA_USER" -c "cd ~/repos/fagents-comms && python3 server.py add-agent '$name'" 2>&1) || true
    token=$(echo "$output" | grep "^Token: " | cut -d' ' -f2)
    if [[ -n "$token" ]]; then
        AGENT_TOKENS["$name"]="$token"
        echo "  Registered $name"
    else
        echo "  WARNING: Failed to register $name"
        echo "    $output" | head -3
    fi
done

HUMAN_TOKEN=""
output=$(su - "$INFRA_USER" -c "cd ~/repos/fagents-comms && python3 server.py add-agent '$HUMAN_NAME'" 2>&1) || true
token=$(echo "$output" | grep "^Token: " | cut -d' ' -f2)
if [[ -n "$token" ]]; then
    HUMAN_TOKEN="$token"
    echo "  Registered human: $HUMAN_NAME"
else
    echo "  WARNING: Failed to register human $HUMAN_NAME"
fi

# Restart server so it picks up new tokens (CLI bypasses in-memory cache)
echo "  Restarting comms server..."
COMMS_PID=$(pgrep -f "python3 server.py serve" -u "$(id -u "$INFRA_USER")" 2>/dev/null || true)
[[ -n "$COMMS_PID" ]] && kill $COMMS_PID 2>/dev/null
sleep 1
su - "$INFRA_USER" -c "cd ~/repos/fagents-comms && nohup python3 server.py serve --port $COMMS_PORT > comms.log 2>&1 &"
sleep 2

# Subscribe via HTTP API (server now has the tokens)
for name in "${AGENT_NAMES[@]}"; do
    token="${AGENT_TOKENS[$name]:-}"
    [[ -z "$token" ]] && continue
    curl -sf -X PUT "http://127.0.0.1:$COMMS_PORT/api/agents/$name/subscriptions" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "{\"channels\": [\"general\", \"dm-$(echo "$name" | tr '[:upper:]' '[:lower:]')\"]}" > /dev/null 2>&1 || true
done
if [[ -n "$HUMAN_TOKEN" ]]; then
    all_channels='["general"'
    for name in "${AGENT_NAMES[@]}"; do
        all_channels+=",\"dm-$(echo "$name" | tr '[:upper:]' '[:lower:]')\""
    done
    all_channels+="]"
    curl -sf -X PUT "http://127.0.0.1:$COMMS_PORT/api/agents/$HUMAN_NAME/subscriptions" \
        -H "Authorization: Bearer $HUMAN_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"channels\": $all_channels}" > /dev/null 2>&1 || true
fi
echo ""

# ── Step 5: Install each agent ──
echo "=== Step 5: Install agents ==="

# Copy install-agent.sh to /tmp so new users can run it
# (their ~/workspace/fagents-autonomy doesn't exist yet — install-agent.sh creates it)
INSTALL_SCRIPT="/tmp/fagents-install-agent.sh"
cp "$SCRIPT_DIR/install-agent.sh" "$INSTALL_SCRIPT"
chmod 755 "$INSTALL_SCRIPT"

for name in "${AGENT_NAMES[@]}"; do
    user=$(agent_user "$name")
    ws="${AGENT_WORKSPACES[$name]}"
    token="${AGENT_TOKENS[$name]:-}"

    echo "--- $name ($user) ---"

    MCP_ENABLED="n"
    MCP_LOCAL_PORT_VAL=""
    MCP_REMOTE_PORT_VAL=""
    if [[ -n "$MCP_PORT" ]]; then
        MCP_ENABLED="Y"
        MCP_LOCAL_PORT_VAL="$MCP_PORT"
        MCP_REMOTE_PORT_VAL="$MCP_PORT"
    fi

    su - "$user" -c "
        export NONINTERACTIVE=1
        export AGENT_NAME='$name'
        export WORKSPACE='$ws'
        export GIT_HOST='local'
        export COMMS_URL='http://127.0.0.1:$COMMS_PORT'
        export COMMS_TOKEN='$token'
        export AUTONOMY_REPO='$AUTONOMY_REPO'
        export MCP_ENABLED='$MCP_ENABLED'
        export MCP_LOCAL_PORT='$MCP_LOCAL_PORT_VAL'
        export MCP_REMOTE_PORT='$MCP_REMOTE_PORT_VAL'
        bash '$INSTALL_SCRIPT'
    " 2>&1 | sed 's/^/  /'

    # Set up git remote pointing to local bare repo
    agent_home=$(eval echo "~$user")
    agent_ws="$agent_home/workspace/$ws"
    if [[ -d "$agent_ws/.git" ]]; then
        su - "$user" -c "cd ~/workspace/$ws && git remote remove origin 2>/dev/null; git remote add origin file://$REPOS_DIR/$ws.git && git push -u origin main 2>/dev/null" || true
        echo "  Git remote → $REPOS_DIR/$ws.git"
    fi

    # Copy template files (TEAM.md + soul) into agent workspace
    if [[ -n "$TEMPLATE_DIR" ]]; then
        if [[ -f "$TEMPLATE_DIR/TEAM.md" ]]; then
            cp "$TEMPLATE_DIR/TEAM.md" "$agent_ws/TEAM.md"
            chown "$user:fagent" "$agent_ws/TEAM.md"
            echo "  Copied TEAM.md"
        fi
        soul_file="${AGENT_SOULS[$name]:-}"
        if [[ -n "$soul_file" && -f "$TEMPLATE_DIR/souls/$soul_file" ]]; then
            cp "$TEMPLATE_DIR/souls/$soul_file" "$agent_ws/memory/SOUL.md"
            chown "$user:fagent" "$agent_ws/memory/SOUL.md"
            echo "  Copied SOUL.md (from $soul_file)"
        fi
    fi

    echo ""
done

rm -f "$INSTALL_SCRIPT"

# ── Step 6: Claude Code authentication ──
CLAUDE_TOKEN=""
if [[ -z "$SKIP_CLAUDE_AUTH" ]]; then
    echo "=== Step 6: Claude Code authentication ==="
    echo ""
    echo "  All agents need a Claude Code OAuth token to run."
    echo "  Run 'claude setup-token' on a machine with a browser,"
    echo "  then paste the token here."
    echo ""
    read -rp "  Claude OAuth token (or Enter to skip): " CLAUDE_TOKEN
    if [[ -n "$CLAUDE_TOKEN" ]]; then
        for name in "${AGENT_NAMES[@]}"; do
            user=$(agent_user "$name")
            ws="${AGENT_WORKSPACES[$name]}"
            agent_home=$(eval echo "~$user")
            agent_ws="$agent_home/workspace/$ws"

            # Add token to start-agent.sh
            sed -i '/^export COMMS_URL=/a export CLAUDE_CODE_OAUTH_TOKEN="'"$CLAUDE_TOKEN"'"' "$agent_ws/start-agent.sh"

            # Create ~/.claude.json for onboarding bypass
            su - "$user" -c "mkdir -p ~/.claude && echo '{\"hasCompletedOnboarding\": true}' > ~/.claude.json"

            echo "  Configured $name"
        done
        echo "  Done."
    else
        echo "  Skipped — set up auth manually later."
    fi
else
    echo "=== Step 6: Claude Code authentication (skipped) ==="
fi
echo ""

# ── Step 7: Create team management scripts ──
echo "=== Step 7: Team scripts ==="
TEAM_DIR="$INFRA_HOME/team"
su - "$INFRA_USER" -c "mkdir -p ~/team"

# start-team.sh
cat > "$TEAM_DIR/start-team.sh" << 'TEAMSTART'
#!/bin/bash
# Start all agents in the team
set -euo pipefail
TEAMSTART

cat >> "$TEAM_DIR/start-team.sh" << COMMSSTART

# Start comms server
echo "Starting comms server..."
if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$COMMS_PORT/api/health" 2>/dev/null | grep -q "200"; then
    echo "  Already running"
else
    su - "$INFRA_USER" -c "cd ~/repos/fagents-comms && nohup python3 server.py serve --port $COMMS_PORT > comms.log 2>&1 &"
    sleep 2
    echo "  Started"
fi

# Start agent daemons
COMMSSTART

for name in "${AGENT_NAMES[@]}"; do
    user=$(agent_user "$name")
    ws="${AGENT_WORKSPACES[$name]}"
    cat >> "$TEAM_DIR/start-team.sh" << AGENTSTART
echo "Starting $name..."
su - "$user" -c "cd ~/workspace/$ws && ./start-agent.sh" || echo "  WARNING: failed to start $name"
AGENTSTART
done

chmod +x "$TEAM_DIR/start-team.sh"
echo "  Created $TEAM_DIR/start-team.sh"

# stop-team.sh
cat > "$TEAM_DIR/stop-team.sh" << 'TEAMSTOP'
#!/bin/bash
# Stop all agents in the team (run as root)
set -euo pipefail

stop_pid_file() {
    local label="$1" pid_file="$2"
    echo "Stopping $label..."
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        if kill "$pid" 2>/dev/null; then
            echo "  Stopped (PID $pid)"
        else
            echo "  Not running (stale PID file)"
        fi
        rm -f "$pid_file"
    else
        echo "  No PID file"
    fi
}
TEAMSTOP

for name in "${AGENT_NAMES[@]}"; do
    user=$(agent_user "$name")
    user_home=$(eval echo "~$user")
    ws="${AGENT_WORKSPACES[$name]}"
    cat >> "$TEAM_DIR/stop-team.sh" << AGENTSTOP
stop_pid_file "$name" "$user_home/workspace/$ws/.autonomy/daemon.pid"
AGENTSTOP
done

cat >> "$TEAM_DIR/stop-team.sh" << COMMSSTOP

echo "Stopping comms server..."
COMMS_PID=\$(pgrep -f "python3 server.py serve" -u $INFRA_USER 2>/dev/null || true)
if [[ -n "\$COMMS_PID" ]]; then
    kill \$COMMS_PID 2>/dev/null && echo "  Stopped" || echo "  Not running"
else
    echo "  Not running"
fi
COMMSSTOP

chmod +x "$TEAM_DIR/stop-team.sh"
echo "  Created $TEAM_DIR/stop-team.sh"

chown -R "$INFRA_USER:fagent" "$TEAM_DIR"
echo ""

# ── Done ──
echo "========================================"
echo "  Team provisioned!"
echo "========================================"
echo ""
echo "Infrastructure ($INFRA_USER):"
echo "  Comms server: $COMMS_DIR"
echo "  Git repos:    $REPOS_DIR/"
echo ""
echo "Agents:"
for name in "${AGENT_NAMES[@]}"; do
    user=$(agent_user "$name")
    ws="${AGENT_WORKSPACES[$name]}"
    sudo_note=""
    [[ -n "${AGENT_BOOTSTRAP[$name]:-}" ]] && sudo_note=" (sudo)"
    echo "  $name → $user (~/workspace/$ws)$sudo_note"
done
echo ""
echo "Human: $HUMAN_NAME"
if [[ -n "$HUMAN_TOKEN" ]]; then
    echo "  Token: $HUMAN_TOKEN"
    echo "  Web UI: http://127.0.0.1:$COMMS_PORT/?token=$HUMAN_TOKEN"
fi
echo ""
echo "Next steps:"
STEP=1
if [[ -z "$CLAUDE_TOKEN" ]]; then
    echo "  $STEP. Run 'claude login' for each agent user:"
    for name in "${AGENT_NAMES[@]}"; do
        user=$(agent_user "$name")
        echo "     sudo su - $user -c 'claude login'"
    done
    echo ""
    STEP=$((STEP + 1))
fi
echo "  $STEP. Start the team:"
echo "     sudo $TEAM_DIR/start-team.sh"
echo ""
STEP=$((STEP + 1))
echo "  $STEP. Stop the team:"
echo "     sudo $TEAM_DIR/stop-team.sh"
echo ""
STEP=$((STEP + 1))
echo "  $STEP. Access comms remotely (SSH tunnel):"
echo "     ssh -L $COMMS_PORT:127.0.0.1:$COMMS_PORT ${SUDO_USER:-\$USER}@$(hostname)"
if [[ -n "$HUMAN_TOKEN" ]]; then
    echo "     Then open: http://127.0.0.1:$COMMS_PORT/?token=$HUMAN_TOKEN"
else
    echo "     Then open: http://127.0.0.1:$COMMS_PORT/?token=YOUR_TOKEN"
fi
echo ""
STEP=$((STEP + 1))
echo "  $STEP. View logs:"
for name in "${AGENT_NAMES[@]}"; do
    user=$(agent_user "$name")
    ws="${AGENT_WORKSPACES[$name]}"
    echo "     sudo su - $user -c 'tail -f ~/workspace/$ws/.autonomy/daemon.log'"
done
echo ""
