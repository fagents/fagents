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
#   --verbose                      Show full output (default: summary only)
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
VERBOSE=""
TEMPLATE=""
AGENTS=()
HUMAN_NAMES=()
INFRA_USER="fagents"
HARDENING_DONE=""

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
        --verbose|-v)   VERBOSE=1; shift ;;
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

# ── Output helpers ──
BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'
log_verbose() { if [[ -n "$VERBOSE" ]]; then sed 's/^/  /'; else cat > /dev/null; fi; }
log_step() { echo ""; echo -e "${BOLD}=== $1 ===${NC}"; }
log_ok() { echo -e "  ${GREEN}✓${NC} $1"; }
log_warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
log_err() { echo -e "  ${RED}✗${NC} $1"; }

# ── Optional: Machine hardening ──
SETUP_SEC="$SCRIPT_DIR/setup-security.sh"
if [[ -f "$SETUP_SEC" ]]; then
    echo ""
    echo "Before we set up your team, want to harden this machine?"
    echo "(Firewall, SSH lockdown, auto-updates, audit logging)"
    echo ""
    echo "You'll need your laptop's SSH public key. If you don't have one,"
    echo "run this on your laptop first:"
    echo ""
    echo "  ssh-keygen -t ed25519 && cat ~/.ssh/id_ed25519.pub"
    echo ""
    read -rp "Run security hardening? [y/N]: " run_sec
    if [[ "$run_sec" =~ ^[Yy] ]]; then
        bash "$SETUP_SEC" --comms-port "$COMMS_PORT" ${VERBOSE:+--verbose}
        HARDENING_DONE=1
    else
        echo "  Skipping — you can run setup-security.sh manually later."
    fi
fi

# ── Load template if specified ──
TEMPLATE_DIR=""
declare -A AGENT_SOULS
declare -A AGENT_MEMORIES
declare -A AGENT_BOOTSTRAP
declare -A AGENT_CHANNELS
declare -A AGENT_ROLES
TEMPLATE_HUMANS=()
TEMPLATE_HUMAN_CHANNELS=()
HUMAN_ROLES=()
HUMAN_CHANNELS=()
HUMAN_PAIRED_AGENTS=()

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
        memory=$(echo "$line" | jq -r '.memory // empty')
        is_bootstrap=$(echo "$line" | jq -r '.bootstrap // false')
        role=$(echo "$line" | jq -r '.role // empty')
        channels=$(echo "$line" | jq -c '.channels // empty')
        AGENTS+=("$name")
        [[ -n "$soul" ]] && AGENT_SOULS["$name"]="$soul"
        [[ -n "$memory" ]] && AGENT_MEMORIES["$name"]="$memory"
        [[ "$is_bootstrap" == "true" ]] && AGENT_BOOTSTRAP["$name"]=1
        [[ -n "$role" ]] && AGENT_ROLES["$name"]="$role"
        [[ -n "$channels" && "$channels" != "null" ]] && AGENT_CHANNELS["$name"]="$channels"
    done < <(jq -c '.agents[]' "$tdir/team.json")
    # Read human roles and channels (comms-only accounts)
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        role=$(echo "$line" | jq -r '.role // "member"')
        channels=$(echo "$line" | jq -c '.channels // empty')
        TEMPLATE_HUMANS+=("$role")
        TEMPLATE_HUMAN_CHANNELS+=("${channels}")
    done < <(jq -c '.humans[]? // empty' "$tdir/team.json")
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
    log_step "Step 0: Introductions"
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
            [[ -n "${AGENT_MEMORIES[$name]:-}" ]] && AGENT_MEMORIES["$new_name"]="${AGENT_MEMORIES[$name]}" && unset "AGENT_MEMORIES[$name]"
            [[ -n "${AGENT_BOOTSTRAP[$name]:-}" ]] && AGENT_BOOTSTRAP["$new_name"]=1 && unset "AGENT_BOOTSTRAP[$name]"
            [[ -n "${AGENT_CHANNELS[$name]:-}" ]] && AGENT_CHANNELS["$new_name"]="${AGENT_CHANNELS[$name]}" && unset "AGENT_CHANNELS[$name]"
            [[ -n "${AGENT_ROLES[$name]:-}" ]] && AGENT_ROLES["$new_name"]="${AGENT_ROLES[$name]}" && unset "AGENT_ROLES[$name]"
        fi
        RENAMED_AGENTS+=("$new_name")
    done
    AGENTS=("${RENAMED_AGENTS[@]}")
fi

# ── Interactive confirmation ──
echo ""
echo "Agents: ${AGENTS[*]}"
prompt COMMS_PORT "Comms server port" "$COMMS_PORT"

# Ask for human names
echo ""
if [[ ${#TEMPLATE_HUMANS[@]} -gt 0 ]]; then
    echo "Name the humans who'll use comms:"
    declare -A _role_idx
    for i in "${!TEMPLATE_HUMANS[@]}"; do
        role="${TEMPLATE_HUMANS[$i]}"
        _role_idx[$role]=$(( ${_role_idx[$role]:-0} + 1 ))
        n=${_role_idx[$role]}
        label="${role^} $n"
        read -rp "  $label: " human_name
        if [[ -n "$human_name" ]]; then
            HUMAN_NAMES+=("$human_name")
            HUMAN_ROLES+=("$role")
            HUMAN_CHANNELS+=("${TEMPLATE_HUMAN_CHANNELS[$i]:-}")
        fi
    done
    unset _role_idx
    # Pair humans with agents by role (positional within each role)
    declare -A _role_agents
    for name in "${AGENTS[@]}"; do
        r="${AGENT_ROLES[$name]:-}"
        [[ -n "$r" ]] && _role_agents[$r]+="$name "
    done
    declare -A _pair_idx
    for i in "${!HUMAN_NAMES[@]}"; do
        role="${HUMAN_ROLES[$i]}"
        idx=${_pair_idx[$role]:-0}
        read -ra _agents_arr <<< "${_role_agents[$role]:-}"
        HUMAN_PAIRED_AGENTS+=("${_agents_arr[$idx]:-}")
        _pair_idx[$role]=$(( idx + 1 ))
    done
    unset _role_agents _pair_idx _agents_arr
else
    echo "A human account is needed to access the web UI and send messages."
    prompt human_name "Your name" ""
    if [[ -n "$human_name" ]]; then
        HUMAN_NAMES+=("$human_name")
        HUMAN_ROLES+=("")
        HUMAN_CHANNELS+=("")
        HUMAN_PAIRED_AGENTS+=("")
    fi
fi
if [[ ${#HUMAN_NAMES[@]} -eq 0 ]]; then
    echo "ERROR: At least one human name is required." >&2
    exit 1
fi

# Ask for Claude OAuth token upfront (so install runs unattended after this)
CLAUDE_TOKEN=""
if [[ -z "$SKIP_CLAUDE_AUTH" ]]; then
    echo ""
    echo "All agents need a Claude Code OAuth token to run."
    echo "Run 'claude setup-token' on a machine with a browser, then paste it here."
    read -rp "Claude OAuth token (or Enter to skip): " CLAUDE_TOKEN
fi

echo ""
echo "  Infra user:  $INFRA_USER (owns comms + git repos)"
echo "  Agents:      ${AGENTS[*]}"
echo "  Humans:      ${HUMAN_NAMES[*]}"
echo "  Comms:       127.0.0.1:$COMMS_PORT"
[[ -n "$CLAUDE_TOKEN" ]] && echo "  Claude auth: provided" || echo "  Claude auth: skip (set up manually later)"

# Warn about sudo agents
for name in "${AGENTS[@]}"; do
    if [[ -n "${AGENT_BOOTSTRAP[$name]:-}" ]]; then
        echo ""
        log_warn " $name WILL HAVE SUDO. It can break your system. Mistakes will happen."
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
log_step "Step 1: Create users"
groupadd -f fagent

# Create infra user
if id "$INFRA_USER" &>/dev/null; then
    log_ok "$INFRA_USER (infra) already exists"
else
    useradd -m -g fagent -s /bin/bash "$INFRA_USER"
    log_ok "Created $INFRA_USER (infra)"
fi
INFRA_HOME=$(eval echo "~$INFRA_USER")

# Create agent users
for name in "${AGENT_NAMES[@]}"; do
    user=$(agent_user "$name")
    if id "$user" &>/dev/null; then
        log_ok "$user already exists"
    else
        useradd -m -g fagent -s /bin/bash "$user"
        log_ok "Created $user"
    fi
    # Grant sudo to bootstrap/ops agent
    if [[ -n "${AGENT_BOOTSTRAP[$name]:-}" ]]; then
        if [[ ! -f "/etc/sudoers.d/$user" ]]; then
            echo "$user ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/$user"
            chmod 440 "/etc/sudoers.d/$user"
            log_ok "Granted sudo to $user (bootstrap/ops)"
        fi
    fi
done
echo ""

# ── Step 2: Set up infra (comms + git repos) ──
log_step "Step 2: Infrastructure (under $INFRA_USER)"
REPOS_DIR="$INFRA_HOME/repos"
su - "$INFRA_USER" -c "mkdir -p ~/repos"

# Clone fagents-comms: bare repo in repos/, working copy in workspace/
COMMS_BARE="$INFRA_HOME/repos/fagents-comms.git"
COMMS_DIR="$INFRA_HOME/workspace/fagents-comms"
if [[ -d "$COMMS_BARE" ]]; then
    log_ok "fagents-comms.git already at $COMMS_BARE"
else
    su - "$INFRA_USER" -c "git clone --bare '$COMMS_REPO' ~/repos/fagents-comms.git && git -C ~/repos/fagents-comms.git remote remove origin 2>/dev/null; true" 2>&1 | log_verbose
fi
chmod -R g+rX "$COMMS_BARE"
su - "$INFRA_USER" -c "mkdir -p ~/workspace"
if [[ -d "$COMMS_DIR" ]]; then
    log_ok "fagents-comms working copy already at $COMMS_DIR"
else
    su - "$INFRA_USER" -c "git clone ~/repos/fagents-comms.git ~/workspace/fagents-comms" 2>&1 | log_verbose
fi

# Clone fagents-autonomy as bare repo (shared, detached from GitHub)
SHARED_AUTONOMY="$INFRA_HOME/repos/fagents-autonomy.git"
if [[ -d "$SHARED_AUTONOMY" ]]; then
    log_ok "fagents-autonomy already at $SHARED_AUTONOMY"
else
    su - "$INFRA_USER" -c "git clone --bare '$AUTONOMY_REPO' ~/repos/fagents-autonomy.git && git -C ~/repos/fagents-autonomy.git remote remove origin 2>/dev/null; true" 2>&1 | log_verbose
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
        log_ok "Repo $ws.git already exists"
    else
        su - "$INFRA_USER" -c "git init --bare -b main ~/repos/$ws.git" 2>&1 | log_verbose
        log_ok "Created bare repo: $ws.git"
    fi
done
# Make all repos group-writable with setgid so agents can push/pull
# core.sharedRepository=group tells git to respect group permissions on new objects
chmod -R g+rwX "$REPOS_DIR"
find "$REPOS_DIR" -type d -exec chmod g+s {} +
for repo in "$REPOS_DIR"/*.git; do
    git -C "$repo" config core.sharedRepository group
done

# Allow all users to work with repos owned by other users in the group
git config --system safe.directory '*'
echo ""

# ── Step 3: Register agents + human (CLI — before server starts) ──
log_step "Step 3: Register agents + human"
declare -A AGENT_TOKENS
declare -A HUMAN_TOKENS

# Channels created via HTTP API after server starts (Step 4) — allows setting ACLs

# Register via CLI (writes tokens.json directly — server not running yet)
for name in "${AGENT_NAMES[@]}"; do
    output=$(su - "$INFRA_USER" -c "cd ~/workspace/fagents-comms && python3 server.py add-agent '$name'" 2>&1) || true
    token=$(echo "$output" | grep "^Token: " | cut -d' ' -f2)
    if [[ -n "$token" ]]; then
        AGENT_TOKENS["$name"]="$token"
        log_ok "Registered $name"
    else
        log_warn " Failed to register $name"
        echo "    $output" | head -3
    fi
done

for human in "${HUMAN_NAMES[@]}"; do
    output=$(su - "$INFRA_USER" -c "cd ~/workspace/fagents-comms && python3 server.py add-agent '$human'" 2>&1) || true
    token=$(echo "$output" | grep "^Token: " | cut -d' ' -f2)
    if [[ -n "$token" ]]; then
        HUMAN_TOKENS["$human"]="$token"
        log_ok "Registered human: $human"
    else
        log_warn " Failed to register human $human"
    fi
done
echo ""

# ── Step 4: Start comms server (tokens already on disk) ──
log_step "Step 4: Start comms server"
if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$COMMS_PORT/api/health" 2>/dev/null | grep -q "200"; then
    log_ok "Comms server already running on port $COMMS_PORT"
else
    echo "  Starting comms server on port $COMMS_PORT..."
    su - "$INFRA_USER" -c "cd ~/workspace/fagents-comms && nohup python3 server.py serve --port $COMMS_PORT > comms.log 2>&1 &"
    for i in 1 2 3 4 5; do
        sleep 1
        if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$COMMS_PORT/api/health" 2>/dev/null | grep -q "200"; then
            log_ok "Comms server running"
            break
        fi
        if [[ $i -eq 5 ]]; then
            log_warn " Comms server may not have started. Check $COMMS_DIR/comms.log"
        fi
    done
fi

# ── Create channels with proper ACLs ──
# Build per-channel allow lists by inverting entity→channel mappings
declare -A CHANNEL_ALLOW

for name in "${AGENT_NAMES[@]}"; do
    tc="${AGENT_CHANNELS[$name]:-}"
    if [[ -n "$tc" && "$tc" != "null" ]]; then
        for ch in $(echo "$tc" | jq -r '.[]'); do
            CHANNEL_ALLOW[$ch]+="$name "
        done
    fi
    dm="$(echo "$name" | tr '[:upper:]' '[:lower:]')s-cove"
    CHANNEL_ALLOW[$dm]+="$name "
done

for i in "${!HUMAN_NAMES[@]}"; do
    human="${HUMAN_NAMES[$i]}"
    tc="${HUMAN_CHANNELS[$i]:-}"
    if [[ -n "$tc" && "$tc" != "null" ]]; then
        for ch in $(echo "$tc" | jq -r '.[]'); do
            CHANNEL_ALLOW[$ch]+="$human "
        done
    fi
    paired="${HUMAN_PAIRED_AGENTS[$i]:-}"
    if [[ -n "$paired" ]]; then
        dm="$(echo "$paired" | tr '[:upper:]' '[:lower:]')s-cove"
        CHANNEL_ALLOW[$dm]+="$human "
    else
        # No explicit pairing — add human to ALL agent coves
        for _agent in "${AGENT_NAMES[@]}"; do
            dm="$(echo "$_agent" | tr '[:upper:]' '[:lower:]')s-cove"
            CHANNEL_ALLOW[$dm]+="$human "
        done
    fi
done

if [[ ${#CHANNEL_ALLOW[@]} -gt 0 ]]; then
    _admin_token="${AGENT_TOKENS[${AGENT_NAMES[0]}]:-}"
    for ch in "${!CHANNEL_ALLOW[@]}"; do
        if [[ "$ch" == "general" ]]; then
            allow='["*"]'
        else
            allow=$(echo "${CHANNEL_ALLOW[$ch]}" | tr ' ' '\n' | sort -u | sed '/^$/d' | jq -R . | jq -sc .)
        fi
        curl -sf -X POST "http://127.0.0.1:$COMMS_PORT/api/channels" \
            -H "Authorization: Bearer $_admin_token" \
            -H "Content-Type: application/json" \
            -d "{\"name\": \"$ch\", \"allow\": $allow}" > /dev/null 2>&1 || true
        # Update ACL on pre-existing channels (POST fails silently if channel exists)
        curl -sf -X PUT "http://127.0.0.1:$COMMS_PORT/api/channels/$ch/acl" \
            -H "Authorization: Bearer $_admin_token" \
            -H "Content-Type: application/json" \
            -d "{\"allow\": $allow}" > /dev/null 2>&1 || true
    done
    log_ok "Channels created with ACLs"
fi

# Subscribe via HTTP API (server has all tokens from disk)
for name in "${AGENT_NAMES[@]}"; do
    token="${AGENT_TOKENS[$name]:-}"
    [[ -z "$token" ]] && continue
    dm="$(echo "$name" | tr '[:upper:]' '[:lower:]')s-cove"
    tc="${AGENT_CHANNELS[$name]:-}"
    if [[ -n "$tc" && "$tc" != "null" ]]; then
        channels=$(echo "$tc" | jq -c ". + [\"$dm\"] | unique")
    else
        channels="[\"general\",\"$dm\"]"
    fi
    curl -sf -X PUT "http://127.0.0.1:$COMMS_PORT/api/agents/$name/channels" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "{\"channels\": $channels}" > /dev/null 2>&1 || true
done
for i in "${!HUMAN_NAMES[@]}"; do
    human="${HUMAN_NAMES[$i]}"
    token="${HUMAN_TOKENS[$human]:-}"
    [[ -z "$token" ]] && continue
    tc="${HUMAN_CHANNELS[$i]:-}"
    paired="${HUMAN_PAIRED_AGENTS[$i]:-}"
    if [[ -n "$tc" && "$tc" != "null" ]]; then
        if [[ -n "$paired" ]]; then
            dm="$(echo "$paired" | tr '[:upper:]' '[:lower:]')s-cove"
            channels=$(echo "$tc" | jq -c ". + [\"$dm\"] | unique")
        else
            channels="$tc"
        fi
    else
        # Fallback: general + all agent DMs (non-template flow)
        channels='["general"'
        for name in "${AGENT_NAMES[@]}"; do
            channels+=",\"$(echo "$name" | tr '[:upper:]' '[:lower:]')s-cove\""
        done
        channels+="]"
    fi
    curl -sf -X PUT "http://127.0.0.1:$COMMS_PORT/api/agents/$human/channels" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "{\"channels\": $channels}" > /dev/null 2>&1 || true
    # Set human profile type (default is ai — hoomans deserve better)
    curl -sf -X PUT "http://127.0.0.1:$COMMS_PORT/api/agents/$human/profile" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d '{"type": "human"}' > /dev/null 2>&1 || true
done
echo ""

# ── Step 5: Install each agent ──
log_step "Step 5: Install agents"

# Copy install-agent.sh to /tmp so new users can run it
# (their ~/workspace/fagents-autonomy doesn't exist yet — install-agent.sh creates it)
INSTALL_SCRIPT="/tmp/fagents-install-agent.sh"
cp "$SCRIPT_DIR/install-agent.sh" "$INSTALL_SCRIPT"
chmod 755 "$INSTALL_SCRIPT"

for name in "${AGENT_NAMES[@]}"; do
    user=$(agent_user "$name")
    ws="${AGENT_WORKSPACES[$name]}"
    token="${AGENT_TOKENS[$name]:-}"

    echo ""
    echo "  $name ($user):"

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
    " 2>&1 | log_verbose

    # Set up git remote pointing to local bare repo
    agent_home=$(eval echo "~$user")
    agent_ws="$agent_home/workspace/$ws"
    if [[ -d "$agent_ws/.git" ]]; then
        su - "$user" -c "cd ~/workspace/$ws && git remote remove origin 2>/dev/null; git remote add origin file://$REPOS_DIR/$ws.git && git push -u origin main 2>/dev/null" 2>&1 | log_verbose || true
        log_ok "Git remote → $REPOS_DIR/$ws.git"
    fi

    # Set wake_channels based on agent role (DM cove + role-specific shared channels)
    dm_channel="$(echo "$name" | tr '[:upper:]' '[:lower:]')s-cove"
    wake_chs="$dm_channel"
    case "${AGENT_ROLES[$name]:-}" in
        parent) wake_chs="$dm_channel,parents-n-bots" ;;
        kid)    wake_chs="$dm_channel,kids-n-bots" ;;
        ops|coo|dev) wake_chs="$dm_channel,general" ;;
    esac
    curl -sf -X PUT "http://127.0.0.1:$COMMS_PORT/api/agents/$name/config" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "{\"wake_channels\": \"$wake_chs\"}" > /dev/null 2>&1 || true
    log_ok "Wake channels → $wake_chs"

    # Copy template files (TEAM.md + soul) into agent workspace
    if [[ -n "$TEMPLATE_DIR" ]]; then
        if [[ -f "$TEMPLATE_DIR/TEAM.md" ]]; then
            # Inject template roles into TEAM_ROLES marker in autonomy's TEAM.md
            team_target=$(readlink -f "$agent_ws/TEAM.md" 2>/dev/null || echo "$agent_ws/TEAM.md")
            if [[ -f "$team_target" ]] && grep -q '<!-- TEAM_ROLES -->' "$team_target"; then
                template_content=$(cat "$TEMPLATE_DIR/TEAM.md")
                awk -v content="$template_content" '{gsub(/<!-- TEAM_ROLES -->/, content)}1' "$team_target" > "$team_target.tmp"
                mv "$team_target.tmp" "$team_target"
                chown "$user:fagent" "$team_target"
                log_ok "Injected team roles into TEAM.md"
            else
                cp "$TEMPLATE_DIR/TEAM.md" "$agent_ws/TEAM.md"
                chown "$user:fagent" "$agent_ws/TEAM.md"
                log_ok "Copied TEAM.md (no marker found)"
            fi
        fi
        soul_file="${AGENT_SOULS[$name]:-}"
        if [[ -n "$soul_file" && -f "$TEMPLATE_DIR/souls/$soul_file" ]]; then
            cp "$TEMPLATE_DIR/souls/$soul_file" "$agent_ws/memory/SOUL.md"
            chown "$user:fagent" "$agent_ws/memory/SOUL.md"
            log_ok "Copied SOUL.md (from $soul_file)"
        fi
        memory_file="${AGENT_MEMORIES[$name]:-}"
        if [[ -n "$memory_file" && -f "$TEMPLATE_DIR/memories/$memory_file" ]]; then
            cat "$TEMPLATE_DIR/memories/$memory_file" >> "$agent_ws/memory/MEMORY.md"
            chown "$user:fagent" "$agent_ws/memory/MEMORY.md"
            log_ok "Appended to MEMORY.md (from $memory_file)"
        fi
        # Inject security hardening context into ops/bootstrap agent memory
        if [[ -n "$HARDENING_DONE" && -n "${AGENT_BOOTSTRAP[$name]:-}" ]]; then
            cat >> "$agent_ws/memory/MEMORY.md" <<'SECEOF'

## Security Hardening (setup-security.sh)
- Machine was hardened during install. Check with: `ufw status`, `fail2ban-client status`, `sysctl net.ipv4.tcp_syncookies`
- **Firewall (UFW):** deny all in/out by default. Allowed: SSH in (rate-limited), DNS/HTTP/HTTPS/SSH out. Comms port allowed on loopback only
- **SSH:** key-only auth, root login disabled, password auth disabled. AllowUsers restricted to the installing human. Agents use localhost, not SSH
- **fail2ban:** SSH jail active — 5 retries in 10 min = 1hr ban. Won't trigger on localhost activity
- **Auto-updates:** unattended-upgrades for security patches, auto-reboot at 04:00 if needed
- **Audit logging:** auditd watches /etc/passwd, /etc/shadow, /etc/sudoers, sshd_config, auth.log, cron, firewall. Check with: `ausearch -k identity`
- **Kernel:** SYN cookies, rp_filter, no IP forwarding, no ICMP redirects, dmesg restricted
- **Comms:** runs on localhost — loopback traffic bypasses firewall (UFW before.rules). No SSH tunnel needed in colocated mode
- **If something is blocked:** check `ufw status numbered` and `journalctl -u ufw` before adding rules. Don't disable the firewall — add specific allows
SECEOF
            chown "$user:fagent" "$agent_ws/memory/MEMORY.md"
            log_ok "Injected security hardening context into MEMORY.md"
        fi
        # Copy template prompt overrides (heartbeat variants)
        if [[ -d "$TEMPLATE_DIR/prompts" ]]; then
            mkdir -p "$agent_ws/prompts"
            cp "$TEMPLATE_DIR/prompts/"* "$agent_ws/prompts/" 2>/dev/null || true
            chown -R "$user:fagent" "$agent_ws/prompts"
            log_ok "Copied prompt overrides"
        fi
    fi

    echo ""
done

rm -f "$INSTALL_SCRIPT"

# ── Step 6: Claude Code setup ──
if [[ -z "$SKIP_CLAUDE_AUTH" ]]; then
    log_step "Step 6: Claude Code setup"

    # Install Claude Code per agent (installs to ~/.local/bin/claude)
    for name in "${AGENT_NAMES[@]}"; do
        user=$(agent_user "$name")
        if su - "$user" -c "command -v claude" &>/dev/null; then
            log_ok "$name: Claude Code already installed"
        else
            echo "  $name: Installing Claude Code..."
            su - "$user" -c "curl -fsSL https://claude.ai/install.sh | bash" 2>&1 | tail -3 | log_verbose
            if su - "$user" -c "command -v claude" &>/dev/null; then
                log_ok "$name: Claude Code installed"
            else
                log_warn " Claude Code installation failed for $name"
            fi
        fi
    done

    # Configure OAuth token (collected during interactive setup)
    if [[ -n "$CLAUDE_TOKEN" ]]; then
        for name in "${AGENT_NAMES[@]}"; do
            user=$(agent_user "$name")
            ws="${AGENT_WORKSPACES[$name]}"
            agent_home=$(eval echo "~$user")
            agent_ws="$agent_home/workspace/$ws"

            # Write token to .env (gitignored, not committed)
            echo "export CLAUDE_CODE_OAUTH_TOKEN=\"$CLAUDE_TOKEN\"" > "$agent_ws/.env"
            chown "$user:fagent" "$agent_ws/.env"
            chmod 600 "$agent_ws/.env"

            # Create ~/.claude.json for onboarding bypass
            su - "$user" -c "mkdir -p ~/.claude && echo '{\"hasCompletedOnboarding\": true}' > ~/.claude.json"

            log_ok "Configured $name"
        done
        log_ok "OAuth configured for all agents"
    else
        echo "  Skipped — set up auth manually later."
    fi
else
    log_step "Step 6: Claude Code setup (skipped)"
fi
echo ""

# ── Step 7: Create team management scripts ──
log_step "Step 7: Team scripts"
TEAM_DIR="$INFRA_HOME/team"
su - "$INFRA_USER" -c "mkdir -p ~/team"

# start-comms.sh
cat > "$TEAM_DIR/start-comms.sh" << STARTCOMMS
#!/bin/bash
# Start the comms server
set -euo pipefail
echo "Starting comms server..."
if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$COMMS_PORT/api/health" 2>/dev/null | grep -q "200"; then
    echo "  Already running"
else
    su - "$INFRA_USER" -c "cd ~/workspace/fagents-comms && nohup python3 server.py serve --port $COMMS_PORT > comms.log 2>&1 &"
    sleep 2
    echo "  Started"
fi
STARTCOMMS
chmod +x "$TEAM_DIR/start-comms.sh"

# stop-comms.sh
cat > "$TEAM_DIR/stop-comms.sh" << STOPCOMMS
#!/bin/bash
# Stop the comms server
set -euo pipefail
echo "Stopping comms server..."
COMMS_PID=\$(pgrep -f "python3 server.py serve" -u $INFRA_USER 2>/dev/null || true)
if [[ -n "\$COMMS_PID" ]]; then
    kill \$COMMS_PID 2>/dev/null && echo "  Stopped" || echo "  Not running"
else
    echo "  Not running"
fi
STOPCOMMS
chmod +x "$TEAM_DIR/stop-comms.sh"

# start-team.sh
cat > "$TEAM_DIR/start-team.sh" << 'STARTAGENTS'
#!/bin/bash
# Start agent daemons
set -euo pipefail
STARTAGENTS
for name in "${AGENT_NAMES[@]}"; do
    user=$(agent_user "$name")
    ws="${AGENT_WORKSPACES[$name]}"
    cat >> "$TEAM_DIR/start-team.sh" << AGENTSTART
echo "Starting $name..."
su - "$user" -c "cd ~/workspace/$ws && ./start-agent.sh" || echo "  WARNING: failed to start $name"
AGENTSTART
done
chmod +x "$TEAM_DIR/start-team.sh"

# stop-team.sh
cat > "$TEAM_DIR/stop-team.sh" << 'STOPAGENTS'
#!/bin/bash
# Stop agent daemons
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
STOPAGENTS
for name in "${AGENT_NAMES[@]}"; do
    user=$(agent_user "$name")
    user_home=$(eval echo "~$user")
    ws="${AGENT_WORKSPACES[$name]}"
    cat >> "$TEAM_DIR/stop-team.sh" << AGENTSTOP
stop_pid_file "$name" "$user_home/workspace/$ws/.autonomy/daemon.pid"
AGENTSTOP
done
chmod +x "$TEAM_DIR/stop-team.sh"

# start-fagents.sh (shortcut: comms + agents)
cat > "$TEAM_DIR/start-fagents.sh" << STARTALL
#!/bin/bash
# Start everything: comms server + agent daemons
set -euo pipefail
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
"\$SCRIPT_DIR/start-comms.sh"
"\$SCRIPT_DIR/start-team.sh"
STARTALL
chmod +x "$TEAM_DIR/start-fagents.sh"

# stop-fagents.sh (shortcut: agents + comms)
cat > "$TEAM_DIR/stop-fagents.sh" << STOPALL
#!/bin/bash
# Stop everything: agent daemons + comms server
set -euo pipefail
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
"\$SCRIPT_DIR/stop-team.sh"
"\$SCRIPT_DIR/stop-comms.sh"
STOPALL
chmod +x "$TEAM_DIR/stop-fagents.sh"

log_ok "Created $TEAM_DIR/{start,stop}-{fagents,agents,comms}.sh"

chown -R "$INFRA_USER:fagent" "$TEAM_DIR"
echo ""

# ── Auto-start if token provided ──
if [[ -n "$CLAUDE_TOKEN" ]]; then
    echo "Starting the team..."
    "$TEAM_DIR/start-fagents.sh"
    echo ""
fi

# ── Done ──
echo "========================================"
echo "  Team provisioned!"
echo "========================================"
echo ""
echo "Agents:"
for name in "${AGENT_NAMES[@]}"; do
    user=$(agent_user "$name")
    ws="${AGENT_WORKSPACES[$name]}"
    echo "  $name → $user (~/workspace/$ws)"
done
echo ""
if [[ -n "$CLAUDE_TOKEN" ]]; then
    echo "========================================"
    echo "  The team is running. Head to comms:"
    echo "========================================"
    echo ""
    for human in "${HUMAN_NAMES[@]}"; do
        token="${HUMAN_TOKENS[$human]:-}"
        [[ -n "$token" ]] && echo "  $human: http://127.0.0.1:$COMMS_PORT/?token=$token"
    done
    echo ""
    echo "  Say hi on #general — everyone's there."
    echo ""
else
    echo "========================================"
    echo "  What now, hooman?"
    echo "========================================"
    echo ""
    echo "  1. Give the agents brains (they need Claude to think):"
    for name in "${AGENT_NAMES[@]}"; do
        user=$(agent_user "$name")
        echo "     sudo su - $user -c 'claude login'"
    done
    echo ""
    echo "  2. Wake the team:"
    echo "     sudo $TEAM_DIR/start-fagents.sh"
    echo ""
    echo "  3. Head to comms — say hi on #general."
    for human in "${HUMAN_NAMES[@]}"; do
        token="${HUMAN_TOKENS[$human]:-YOUR_TOKEN}"
        echo "     $human: http://127.0.0.1:$COMMS_PORT/?token=$token"
    done
    echo ""
fi
