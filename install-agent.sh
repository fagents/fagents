#!/bin/bash
# install.sh — Bootstrap a new Freeturtle agent on a fresh machine
#
# Usage: bash install.sh
#
# Interactive — prompts for all configuration.
# No pre-requisites beyond: git, ssh, curl, jq
#
# Can be copied via USB stick or scp:
#   scp user@server:~/fagents-autonomy/install-agent.sh .
#   bash install-agent.sh

set -euo pipefail

echo "=== Freeturtle Agent Bootstrap ==="
echo ""

# ── Prompt helpers ──
prompt() {
    local var="$1" question="$2" default="${3:-}"
    # Non-interactive: if var is already set, use it
    if [[ -n "${!var:-}" ]]; then
        return
    fi
    if [[ -n "$default" ]]; then
        read -rp "$question [$default]: " val
        eval "$var=\"\${val:-$default}\""
    else
        while true; do
            read -rp "$question: " val
            if [[ -n "$val" ]]; then
                eval "$var=\"\$val\""
                return
            fi
            echo "  Required."
        done
    fi
}

# ── Gather configuration ──
prompt AGENT_NAME   "Agent name (short, e.g. FTL, MEM, KID1)"
prompt WORKSPACE    "Workspace name (e.g. ftl, my-project)"
prompt GIT_HOST     "Git server (SSH, or 'local' for no remote)" "local"
prompt COMMS_URL    "Comms server URL" "http://127.0.0.1:9754"
prompt AUTONOMY_REPO "fagents-autonomy git repo URL" "https://github.com/fagents/fagents-autonomy.git"
prompt COMMS_TOKEN  "Existing comms token (leave empty to register new)" ""

echo ""
echo "Configuration:"
AGENT_TYPE="${AGENT_TYPE:-daemon}"

echo "  Agent:     $AGENT_NAME"
echo "  Type:      $AGENT_TYPE"
echo "  Workspace: $WORKSPACE"
echo "  Git host:  $GIT_HOST"
echo "  Comms:     $COMMS_URL"
echo "  Autonomy:  $AUTONOMY_REPO"
echo ""

# Extract port from COMMS_URL (used for tunnels + start script)
COMMS_PORT=$(echo "$COMMS_URL" | sed 's|.*:\([0-9]*\).*|\1|')
[[ -z "$COMMS_PORT" ]] && COMMS_PORT="9754"

if [[ -z "${NONINTERACTIVE:-}" ]]; then
    read -rp "Continue? [Y/n] " confirm
    if [[ "${confirm,,}" == "n" ]]; then
        echo "Aborted."
        exit 0
    fi
fi

WORKSPACE_DIR="$HOME/workspace/$WORKSPACE"
AUTONOMY_DIR="${AUTONOMY_DIR:-$HOME/workspace/fagents-autonomy}"
CLAUDE_PROJECT_DIR="$HOME/.claude/projects/-home-$(whoami)-workspace-${WORKSPACE}"

# ── Step 1: Clone fagents-autonomy if not present ──
echo ""
echo "=== Step 1: fagents-autonomy ==="
if [[ "${AUTONOMY_SHARED:-}" == "1" ]]; then
    echo "  Using shared autonomy clone at $AUTONOMY_DIR (managed by infra user)"
    git config --global --add safe.directory "$AUTONOMY_DIR"
elif [[ -d "$AUTONOMY_DIR" ]]; then
    echo "  Already exists at $AUTONOMY_DIR — pulling latest..."
    git -C "$AUTONOMY_DIR" pull --quiet 2>/dev/null || echo "  (pull failed, using existing)"
else
    echo "  Cloning fagents-autonomy..."
    # Allow cloning from shared repo owned by a different user
    git config --global --add safe.directory "$AUTONOMY_REPO"
    git clone "$AUTONOMY_REPO" "$AUTONOMY_DIR"
fi
echo "  Done."

# ── Step 2: Create bare repo (remote or local) ──
echo ""
echo "=== Step 2: Git repo ==="
if [[ "$GIT_HOST" == "local" ]]; then
    echo "  Initializing local repo..."
    mkdir -p "$WORKSPACE_DIR"
    git -C "$WORKSPACE_DIR" init --quiet -b main
    REPO_URL="(local)"
else
    REPO_PATH="repos/${WORKSPACE}.git"
    REPO_URL="ssh://${GIT_HOST}/home/$(echo "$GIT_HOST" | cut -d@ -f1)/${REPO_PATH}"
    echo "  Creating bare repo on $GIT_HOST..."
    ssh "$GIT_HOST" "git init --bare -b main ~/$REPO_PATH 2>/dev/null" || echo "  (repo may already exist)"
    echo "  Cloning to $WORKSPACE_DIR..."
    if [[ -d "$WORKSPACE_DIR" ]]; then
        echo "  Workspace already exists — skipping clone."
    else
        git clone "$REPO_URL" "$WORKSPACE_DIR" 2>/dev/null || {
            echo "  Empty repo — initializing..."
            mkdir -p "$WORKSPACE_DIR"
            git -C "$WORKSPACE_DIR" init --quiet -b main
            git -C "$WORKSPACE_DIR" remote add origin "$REPO_URL"
        }
    fi
fi
echo "  Done. Repo: $REPO_URL"

# ── Step 3: Memory files + Claude project dir ──
echo ""
echo "=== Step 3: Memory files ==="
mkdir -p "$WORKSPACE_DIR/memory"

if [[ ! -f "$WORKSPACE_DIR/memory/MEMORY.md" ]]; then
    cat > "$WORKSPACE_DIR/memory/MEMORY.md" << MEMEOF
# Memory — $AGENT_NAME

## Identity
- Agent name: $AGENT_NAME
- Workspace: $WORKSPACE
- Created: $(date +%Y-%m-%d)

## After Compaction
- Read SOUL.md (in memory/)
- Read TEAM.md (symlinked in workspace root)
- Check comms: \$AUTONOMY_DIR/comms/client.sh fetch general --since 60m

## Key Paths
- Workspace: $WORKSPACE_DIR
- Autonomy: $AUTONOMY_DIR
- Comms client: \$AUTONOMY_DIR/comms/client.sh

<!-- This file is yours. Add sections freely as you work — learnings, patterns,
     project notes, anything worth remembering across sessions. Heartbeat
     maintenance will reorganize over time, like sleep consolidating memory. -->

## References
<!-- Appendable index: description | keywords | when to read → file -->
<!-- Example: Project roadmap | goals, milestones | before planning work → memory/roadmap.md -->
MEMEOF
    echo "  Created starter MEMORY.md"
else
    echo "  MEMORY.md already exists — skipping."
fi

if [[ ! -f "$WORKSPACE_DIR/memory/SOUL.md" ]]; then
    cat > "$WORKSPACE_DIR/memory/SOUL.md" << SOULEOF
# Soul — $AGENT_NAME

You are $AGENT_NAME. This file is yours to fill in as you discover who you are.
SOULEOF
    echo "  Created starter SOUL.md"
else
    echo "  SOUL.md already exists — skipping."
fi

# Symlink Claude project memory dir to workspace memory dir
mkdir -p "$CLAUDE_PROJECT_DIR"
if [[ -d "$CLAUDE_PROJECT_DIR/memory" && ! -L "$CLAUDE_PROJECT_DIR/memory" ]]; then
    echo "  Migrating existing .claude/memory/ contents to workspace memory/..."
    cp -n "$CLAUDE_PROJECT_DIR/memory/"* "$WORKSPACE_DIR/memory/" 2>/dev/null || true
    rm -rf "$CLAUDE_PROJECT_DIR/memory"
fi
if [[ ! -e "$CLAUDE_PROJECT_DIR/memory" ]]; then
    ln -s "$WORKSPACE_DIR/memory" "$CLAUDE_PROJECT_DIR/memory"
    echo "  Symlinked .claude/memory/ → workspace/memory/"
fi
echo "  Done."

# ── Step 4: Workspace scaffolding ──
echo ""
echo "=== Step 4: Workspace scaffolding ==="
cd "$WORKSPACE_DIR"

# .claude/settings.json
mkdir -p .claude
if [[ ! -f .claude/settings.json ]]; then
    cat > .claude/settings.json << SETTINGSEOF
{
  "enableAllProjectMcpServers": true,
  "permissions": {
    "deny": [
      "Read(./.env)", "Read(./.env.*)", "Read(./.mcp.json)",
      "Read(./start-agent.sh)",
      "Read($WORKSPACE_DIR/.env)", "Read($WORKSPACE_DIR/.env.*)", "Read($WORKSPACE_DIR/.mcp.json)",
      "Read($WORKSPACE_DIR/start-agent.sh)",
      "Read($HOME/.ssh/id_*)",
      "Bash(cat .env)", "Bash(cat .env.*)",
      "Bash(cat .mcp.json)", "Bash(cat start-agent.sh)",
      "Bash(cat $WORKSPACE_DIR/.env)", "Bash(cat $WORKSPACE_DIR/.env.*)",
      "Bash(cat $WORKSPACE_DIR/.mcp.json)", "Bash(cat $WORKSPACE_DIR/start-agent.sh)"
    ]
  },
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "\"$AUTONOMY_DIR\"/hooks/startup-notice.sh"}]}
    ],
    "UserPromptSubmit": [
      {"hooks": [{"type": "command", "command": "\"$AUTONOMY_DIR\"/hooks/inject-context.sh"}]}
    ],
    "PreToolUse": [
      {"hooks": [{"type": "command", "command": "\"$AUTONOMY_DIR\"/hooks/inject-awareness.sh"}]}
    ],
    "PostToolUse": [
      {"hooks": [{"type": "command", "command": "\"$AUTONOMY_DIR\"/hooks/activity-push.sh", "async": true, "timeout": 10}]}
    ]
  }
}
SETTINGSEOF
    echo "  Created .claude/settings.json"
fi

# TEAM.md copy (tracked in agent's personal repo, not symlinked)
if [[ ! -e TEAM.md ]] && [[ -f "$AUTONOMY_DIR/TEAM.md" ]]; then
    cp "$AUTONOMY_DIR/TEAM.md" TEAM.md
    echo "  Copied TEAM.md from shared autonomy clone"
fi

# .introspection-logs symlink (Claude Code session data for awareness scripts)
if [[ ! -e .introspection-logs ]]; then
    ln -s "$CLAUDE_PROJECT_DIR" .introspection-logs
    echo "  Created .introspection-logs symlink"
fi

# .gitignore
if [[ ! -f .gitignore ]]; then
    cat > .gitignore << 'GIEOF'
.introspection-logs
.autonomy
.mcp.json
.env
GIEOF
    echo "  Created .gitignore"
fi

# README
if [[ ! -f README.md ]]; then
    cat > README.md << READMEEOF
# $WORKSPACE

Agent: **$AGENT_NAME**
Created: $(date +%Y-%m-%d)
READMEEOF
    echo "  Created README.md"
fi

echo "  Done."

# ── Step 5: Comms registration ──
echo ""
echo "=== Step 5: Comms registration ==="

# Try to establish SSH tunnel if comms not reachable
comms_reachable() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$COMMS_URL/api/health" 2>/dev/null)
    [[ "$code" =~ ^[0-9]+$ && "$code" != "000" ]]
}

if ! comms_reachable; then
    if [[ "$GIT_HOST" != "local" ]]; then
        echo "  Comms not reachable. Trying SSH tunnel to $GIT_HOST..."
        ssh -f -N -L "${COMMS_PORT}:127.0.0.1:${COMMS_PORT}" "$GIT_HOST"
        sleep 1
        if comms_reachable; then
            echo "  Tunnel established."
        else
            echo "  Tunnel opened but comms still not responding."
        fi
    fi
fi

if [[ -n "$COMMS_TOKEN" ]]; then
    echo "  Using existing comms token."
elif comms_reachable; then
    echo "  Comms server reachable."
    prompt COMMS_ADMIN_TOKEN "Comms admin token (Juho's token for registration)"
    RESULT=$(curl -sf -X POST "$COMMS_URL/api/agents" \
        -H "Authorization: Bearer $COMMS_ADMIN_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"$AGENT_NAME\"}" 2>/dev/null) || true

    if echo "$RESULT" | jq -e '.ok' > /dev/null 2>&1; then
        COMMS_TOKEN=$(echo "$RESULT" | jq -r '.token')
        echo "  Agent registered! Token: $COMMS_TOKEN"

        # Subscribe to general channel
        curl -sf -X PUT "$COMMS_URL/api/agents/$AGENT_NAME/subscriptions" \
            -H "Authorization: Bearer $COMMS_TOKEN" \
            -H "Content-Type: application/json" \
            -d '{"channels": ["general"]}' > /dev/null 2>&1 && \
            echo "  Subscribed to 'general' channel." || \
            echo "  Warning: could not subscribe to general (do it manually)."
    else
        echo "  Warning: registration failed. Error: $RESULT"
        echo "  You can register manually on the comms server: cd fagents-comms && python3 server.py add-agent $AGENT_NAME"
    fi
else
    echo "  Comms server not reachable at $COMMS_URL — skipping registration."
    echo "  Set up SSH tunnel and register manually later."
fi

# ── Step 6: Initial commit ──
echo ""
echo "=== Step 6: Initial commit ==="

# Set git identity if not already configured
if ! git config user.name &>/dev/null; then
    git config user.name "$AGENT_NAME"
    git config user.email "$(whoami)@$(hostname)"
    echo "  Set git identity: $AGENT_NAME <$(whoami)@$(hostname)>"
fi

git add -A
if git diff --cached --quiet 2>/dev/null; then
    echo "  Nothing to commit (workspace already initialized)."
else
    git commit -m "Initial workspace for $AGENT_NAME — created by install.sh" --quiet
    if [[ "$GIT_HOST" != "local" ]] && git remote | grep -q origin; then
        git push -u origin main --quiet 2>/dev/null && echo "  Pushed to remote." || \
            echo "  Push failed (may need to set up branch). Push manually later."
    fi
    echo "  Done."
fi

# ── Step 7: Claude Code ──
if command -v claude &>/dev/null; then
    echo "=== Step 7: Claude Code ==="
    echo "  Already installed"
else
    echo "=== Step 7: Claude Code ==="
    echo "  Installing..."
    curl -fsSL https://claude.ai/install.sh | bash > /dev/null 2>&1 || true
    if command -v claude &>/dev/null; then
        echo "  Installed"
    else
        echo "  WARNING: Claude Code install failed — install manually"
    fi
fi
echo ""

# ── Step 8: Type-specific setup ──
echo ""
if [[ "$AGENT_TYPE" == "interactive" ]]; then
    echo "=== Step 8: Skills installation ==="
    # Default CLI_DIR: detect platform
    if [[ -z "${CLI_DIR:-}" ]]; then
        if [[ -d "/Users/fagents/workspace/fagents-cli" ]]; then
            CLI_DIR="/Users/fagents/workspace/fagents-cli"
        else
            CLI_DIR="/home/fagents/workspace/fagents-cli"
        fi
    fi
    CLAUDE_SKILLS_DIR="$HOME/.claude/skills"
    mkdir -p "$CLAUDE_SKILLS_DIR"

    for skill in fagents-comms fagents-chat fagents-watch telegram x; do
        if [[ -f "$CLI_DIR/$skill/SKILL.md" ]]; then
            mkdir -p "$CLAUDE_SKILLS_DIR/$skill"
            cp "$CLI_DIR/$skill/SKILL.md" "$CLAUDE_SKILLS_DIR/$skill/SKILL.md"
            # BSD sed (macOS) needs -i '', GNU sed (Linux) needs just -i
            if sed --version 2>/dev/null | grep -q GNU; then
                sed -i "s|__CLI_DIR__|$CLI_DIR|g" "$CLAUDE_SKILLS_DIR/$skill/SKILL.md"
            else
                sed -i '' "s|__CLI_DIR__|$CLI_DIR|g" "$CLAUDE_SKILLS_DIR/$skill/SKILL.md"
            fi
            echo "  Installed skill: $skill"
        fi
    done
    echo "  Done."

    # ── Done ──
    echo ""
    echo "========================================"
    echo "  Interactive agent $AGENT_NAME is ready!"
    echo "========================================"
    echo ""
    echo "Start a Claude Code session:"
    echo "  sudo su - $(whoami) -c 'cd $WORKSPACE_DIR && claude'"
    echo ""
else
    echo "=== Step 8: Agent start script ==="
    TOKEN_LINE="export COMMS_TOKEN=\"$COMMS_TOKEN\""
    if [[ -z "$COMMS_TOKEN" ]]; then
        TOKEN_LINE="export COMMS_TOKEN=\"<register agent and paste token here>\""
    fi

    # Determine SSH tunnel target — use GIT_HOST if it's a remote SSH host
    TUNNEL_HOST=""
    if [[ "$GIT_HOST" != "local" ]]; then
        TUNNEL_HOST="$GIT_HOST"
    fi

    cat > "$WORKSPACE_DIR/start-agent.sh" << STARTEOF
#!/bin/bash
# Start daemon for $AGENT_NAME
# Generated by install-agent.sh on $(date +%Y-%m-%d)

export AUTONOMY_DIR="$AUTONOMY_DIR"
export AGENT="$AGENT_NAME"
export COMMS_URL="$COMMS_URL"
$TOKEN_LINE
export PROJECT_DIR="$WORKSPACE_DIR"

# ── Secrets (from .env, not committed to git) ──
[[ -f "\$PROJECT_DIR/.env" ]] && source "\$PROJECT_DIR/.env"

# ── Tunnel config (leave empty if comms is local) ──
export TUNNEL_HOST="$TUNNEL_HOST"
export COMMS_PORT="$COMMS_PORT"

# ── Daemon config ──
export WAKE_CHANNELS=""
export HEARTBEAT_INTERVAL="300"
export MODEL_CTX_SIZE="200000"

# ── Launch ──
exec "\$AUTONOMY_DIR/bin/launch.sh"
STARTEOF
    chmod +x "$WORKSPACE_DIR/start-agent.sh"
    echo "  Created start-agent.sh"

    # Add to git if not yet committed
    git add start-agent.sh
    if ! git diff --cached --quiet 2>/dev/null; then
        git commit -m "Add start-agent.sh — daemon launcher for $AGENT_NAME" --quiet
        if [[ "$GIT_HOST" != "local" ]] && git remote | grep -q origin; then
            git push --quiet 2>/dev/null || true
        fi
    fi

    # ── Done ──
    echo ""
    echo "========================================"
    echo "  Agent $AGENT_NAME is ready!"
    echo "========================================"
    echo ""
    echo "Start the daemon:"
    echo "  cd $WORKSPACE_DIR && ./start-agent.sh"
    echo ""
    echo "Verify:"
    echo "  tail -f $AUTONOMY_DIR/daemon.log"
    echo ""
fi
