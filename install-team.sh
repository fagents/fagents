#!/bin/bash
# install-team.sh — Provision a team of agents on one machine (colocated mode)
#
# Usage: sudo ./install-team.sh [options]
#
# Options:
#   --comms-port PORT       Comms server port (default: 9754)
#   --comms-repo URL        fagents-comms git repo URL (default: GitHub)
#   --skip-claude-auth      Skip Claude Code authentication setup
#   --verbose               Show full output (default: summary only)
#
# Creates a 'fagents' infra user that owns the comms server and git repos.
# Two agents: ops (infra/sudo) + comms (external communications).
# Agents connect via localhost.
#
# Prerequisites: git, python3, curl, jq

set -euo pipefail

# ── Defaults ──
COMMS_PORT=9754
COMMS_REPO="https://github.com/fagents/fagents-comms.git"
SKIP_CLAUDE_AUTH=""
VERBOSE=""
HUMAN_NAMES=()
INFRA_USER="fagents"
HARDENING_DONE=""
EMAIL_PORT=""
EMAIL_CONFIGURED=""

OPENAI_API_KEY=""
X_BEARER_TOKEN=""
X_CONSUMER_KEY=""
X_CONSUMER_SECRET=""
X_ACCESS_TOKEN=""
X_ACCESS_TOKEN_SECRET=""

OPS_AGENT_NAME="${OPS_AGENT_NAME:-Ops}"
COMMS_AGENT_NAME="${COMMS_AGENT_NAME:-Comms}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTONOMY_REPO="https://github.com/fagents/fagents-autonomy.git"
CLI_REPO="https://github.com/fagents/fagents-cli.git"
CLI_DIR=""

# ── Parse args ──
while [[ $# -gt 0 ]]; do
    case "$1" in
        --comms-port)   COMMS_PORT="$2"; shift 2 ;;
        --comms-repo)   COMMS_REPO="$2"; shift 2 ;;
        --skip-claude-auth)    SKIP_CLAUDE_AUTH=1; shift ;;
        --verbose|-v)   VERBOSE=1; shift ;;
        --help|-h)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)  shift ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must run as root (sudo)." >&2
    exit 1
fi

# ── Output helpers ──
BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'
log_verbose() { if [[ -n "$VERBOSE" ]]; then sed 's/^/  /'; else cat > /dev/null; fi; }
# run/run_msg: safe replacements for `cmd 2>&1 | log_verbose` which crashes
# with set -euo pipefail when cmd returns non-zero
run() {
    if [[ -n "${VERBOSE:-}" ]]; then
        "$@" 2>&1 | sed 's/^/  /' || true
    else
        "$@" > /dev/null 2>&1 || true
    fi
}
run_fatal() {
    if [[ -n "${VERBOSE:-}" ]]; then
        "$@" 2>&1 | sed 's/^/  /'
    else
        "$@" > /dev/null 2>&1
    fi
}
log_step() { echo ""; echo -e "${BOLD}=== $1 ===${NC}"; }
log_ok() { echo -e "  ${GREEN}✓${NC} $1"; }
log_warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
log_err() { echo -e "  ${RED}✗${NC} $1"; }

# ── Prerequisites ──
_missing_prereqs=()
for cmd in git curl python3 jq; do
    command -v "$cmd" &>/dev/null || _missing_prereqs+=("$cmd")
done
if [[ ${#_missing_prereqs[@]} -gt 0 ]]; then
    echo ""
    echo "Installing prerequisites: ${_missing_prereqs[*]}"
    run apt-get update -qq
    run apt-get install -y "${_missing_prereqs[@]}"
    for cmd in "${_missing_prereqs[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            log_ok "Installed $cmd"
        else
            log_err "Failed to install $cmd — run: apt-get install -y $cmd"
            exit 1
        fi
    done
fi

# ── MCP helper: add a server to an agent's .mcp.json ──
add_mcp_server() {
    local ws_dir="$1" owner="$2" name="$3" url="$4" api_key="$5"
    local mcp_file="$ws_dir/.mcp.json"

    if [[ -f "$mcp_file" ]]; then
        local tmp
        tmp=$(jq --arg name "$name" --arg url "$url" --arg key "$api_key" \
            '.mcpServers[$name] = {"type": "http", "url": $url, "headers": {"x-api-key": $key}}' \
            "$mcp_file")
        echo "$tmp" > "$mcp_file"
    else
        jq -n --arg name "$name" --arg url "$url" --arg key "$api_key" \
            '{mcpServers: {($name): {"type": "http", "url": $url, "headers": {"x-api-key": $key}}}}' \
            > "$mcp_file"
    fi
    chown "$owner:fagent" "$mcp_file"
    chmod 600 "$mcp_file"
}

# ── Optional: Machine hardening ──
SETUP_SEC="$SCRIPT_DIR/setup-security.sh"
if [[ -f "$SETUP_SEC" && -z "${NONINTERACTIVE:-}" ]]; then
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

# ── Interactive mode ──
prompt() {
    local var="$1" prompt_text="$2" default="$3"
    if [[ -n "${NONINTERACTIVE:-}" && -n "${!var:-}" ]]; then
        return
    fi
    if [[ -n "$default" ]]; then
        if [[ -n "${NONINTERACTIVE:-}" ]]; then
            eval "$var='$default'"
        else
            read -rp "$prompt_text [$default]: " val
            eval "$var='${val:-$default}'"
        fi
    else
        if [[ -n "${NONINTERACTIVE:-}" ]]; then
            return
        fi
        read -rp "$prompt_text: " val
        eval "$var='$val'"
    fi
}

# ── Step 0: Introductions ──
log_step "Step 0: Introductions"
echo ""
echo "Welcome to fagents!"
echo "Your team starts with two agents (ops can add more later):"
echo "  ops  — infrastructure, system admin, sudo, team management"
echo "  comms — Telegram, X, email, voice — your team's interface to the outside world"
echo ""

prompt OPS_AGENT_NAME "Name your ops agent" "$OPS_AGENT_NAME"
prompt COMMS_AGENT_NAME "Name your comms agent" "$COMMS_AGENT_NAME"

# Agent names
OPS_USER="$(echo "$OPS_AGENT_NAME" | tr '[:upper:]' '[:lower:]')"
COMMS_USER="$(echo "$COMMS_AGENT_NAME" | tr '[:upper:]' '[:lower:]')"
AGENT_NAMES=("$OPS_AGENT_NAME" "$COMMS_AGENT_NAME")
AGENT_USERS=("$OPS_USER" "$COMMS_USER")

echo ""
prompt COMMS_PORT "Comms server port" "$COMMS_PORT"

# Ask for human names
echo ""
if [[ -n "${NONINTERACTIVE:-}" && -n "${HUMAN_NAMES_INPUT:-}" ]]; then
    for human_name in $HUMAN_NAMES_INPUT; do
        HUMAN_NAMES+=("$human_name")
    done
else
    echo "A human account is needed to access the web UI and send messages."
    prompt human_name "Your name" ""
    if [[ -n "$human_name" ]]; then
        HUMAN_NAMES+=("$human_name")
    fi
fi
if [[ ${#HUMAN_NAMES[@]} -eq 0 ]]; then
    echo "ERROR: At least one human name is required." >&2
    exit 1
fi

# Ask for Claude OAuth token upfront
CLAUDE_TOKEN="${CLAUDE_TOKEN:-}"
if [[ -z "$SKIP_CLAUDE_AUTH" && -z "${NONINTERACTIVE:-}" ]]; then
    echo ""
    echo "All agents need a Claude Code OAuth token to run."
    echo "If Claude Code is not installed yet, run this first:"
    echo "  curl -fsSL https://claude.ai/install.sh | bash && export PATH=\"\$HOME/.local/bin:\$PATH\" && claude setup-token"
    echo "Then paste the token here."
    read -rp "Claude OAuth token (or Enter to skip): " CLAUDE_TOKEN
fi

# ── Email config (Linux only, scoped to comms agent) ──
EMAIL_PORT=$((COMMS_PORT + 1))
declare -A EMAIL_FROM
declare -A EMAIL_SMTP_USER
declare -A EMAIL_SMTP_PASS
declare -A EMAIL_IMAP_USER
declare -A EMAIL_IMAP_PASS
EMAIL_ENABLED=""
enable_email=""
if [[ -z "${NONINTERACTIVE:-}" ]]; then
    echo ""
    read -rp "Enable email for $COMMS_AGENT_NAME? [y/N]: " enable_email
fi
if [[ "${enable_email,,}" =~ ^y ]]; then
    echo ""
    echo "  Mail server (same host for SMTP and IMAP):"
    prompt smtp_host "    SMTP host" ""
    prompt smtp_port "    SMTP port" "587"
    prompt imap_host "    IMAP host" "$smtp_host"
    prompt imap_port "    IMAP port" "993"
    echo ""
    echo "  Comms agent email credentials:"
    read -rp "    Sends as (from address): " from_addr
    prompt _su "    SMTP user" ""
    read -rsp "    SMTP password: " _sp; echo ""
    prompt _iu "    IMAP user" "$_su"
    read -rsp "    IMAP password (Enter = same as SMTP): " _ip; echo ""
    [[ -z "$_ip" ]] && _ip="$_sp"
    EMAIL_FROM[$COMMS_AGENT_NAME]="$from_addr"
    EMAIL_SMTP_USER[$COMMS_AGENT_NAME]="$_su"
    EMAIL_SMTP_PASS[$COMMS_AGENT_NAME]="$_sp"
    EMAIL_IMAP_USER[$COMMS_AGENT_NAME]="$_iu"
    EMAIL_IMAP_PASS[$COMMS_AGENT_NAME]="$_ip"
    EMAIL_ENABLED=1
fi

# ── Telegram config (scoped to comms agent) ──
declare -A TELEGRAM_BOT_TOKEN
declare -A TELEGRAM_ALLOWED
enable_telegram=""
if [[ -z "${NONINTERACTIVE:-}" ]]; then
    echo ""
    read -rp "Enable Telegram for $COMMS_AGENT_NAME? [y/N]: " enable_telegram
elif [[ -n "${TELEGRAM_ENABLE:-}" ]]; then
    enable_telegram="y"
fi
if [[ "${enable_telegram,,}" =~ ^y ]]; then
    if [[ -n "${NONINTERACTIVE:-}" ]]; then
        TELEGRAM_BOT_TOKEN[$COMMS_AGENT_NAME]="${TELEGRAM_BOT_TOKEN_INPUT:-}"
        TELEGRAM_ALLOWED[$COMMS_AGENT_NAME]="${TELEGRAM_ALLOWED_INPUT:-NONE}"
    else
        echo ""
        echo "  Bot token (from BotFather):"
        read -rp "    Bot token: " _tg_token
        # Validate token
        _bot_name=$(curl -sf --max-time 10 "https://api.telegram.org/bot${_tg_token}/getMe" 2>/dev/null | jq -r '.result.username // empty' 2>/dev/null)
        if [[ -z "$_bot_name" ]]; then
            log_warn "Bot token invalid or unreachable — skipping Telegram"
            _tg_token=""
        else
            log_ok "Bot verified: @$_bot_name"
            TELEGRAM_BOT_TOKEN[$COMMS_AGENT_NAME]="$_tg_token"
            # Generate one-time auth code
            _auth_code="fagents-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' ')"
            echo ""
            echo "  Link your Telegram account:"
            echo "  1. Open @$_bot_name in Telegram"
            echo "  2. Send this exact message:  $_auth_code"
            echo ""
            read -rp "    Press Enter after sending... "
            echo "    Waiting for auth code (up to 30s)..."
            # Single poll — search all messages for the auth code (don't clear first, user may have already sent it)
            _resp=$(curl -sf --max-time 35 "https://api.telegram.org/bot${_tg_token}/getUpdates?timeout=30" 2>/dev/null) || true
            _uid=$(echo "${_resp:-}" | jq -r --arg code "$_auth_code" '[.result[].message | select(.text == $code) | .from.id] | first // empty' 2>/dev/null)
            if [[ -n "$_uid" ]]; then
                _uname=$(echo "$_resp" | jq -r --arg code "$_auth_code" '[.result[].message | select(.text == $code) | .from.username] | first // empty' 2>/dev/null)
                TELEGRAM_ALLOWED[$COMMS_AGENT_NAME]="$_uid"
                log_ok "Verified! Locked to ${_uname:-user} (ID: $_uid)"
            else
                TELEGRAM_ALLOWED[$COMMS_AGENT_NAME]="NONE"
                log_warn "Auth code not received — bot will reject all messages until TELEGRAM_ALLOWED_IDS is set"
            fi
        fi
    fi

    # Optional: OpenAI API key for voice
    if [[ -z "${NONINTERACTIVE:-}" ]]; then
        echo ""
        echo "  Optional: OpenAI API key for voice messages (TTS + Whisper STT)."
        read -rsp "    OpenAI API key (blank to skip): " _openai_key; echo ""
        [[ -n "$_openai_key" ]] && OPENAI_API_KEY="$_openai_key"
    else
        OPENAI_API_KEY="${OPENAI_API_KEY_INPUT:-}"
    fi
fi

# ── X (Twitter) config (scoped to comms agent) ──
enable_x=""
if [[ -z "${NONINTERACTIVE:-}" ]]; then
    echo ""
    read -rp "Enable X (Twitter) for $COMMS_AGENT_NAME? [y/N]: " enable_x
elif [[ -n "${X_ENABLE:-}" ]]; then
    enable_x="y"
fi
if [[ "${enable_x,,}" =~ ^y ]]; then
    if [[ -z "${NONINTERACTIVE:-}" ]]; then
        echo ""
        echo "  X API credentials (from developer.x.com):"
        read -rsp "    Bearer token: " X_BEARER_TOKEN; echo ""
        read -rp  "    Consumer key: " X_CONSUMER_KEY
        read -rsp "    Consumer secret: " X_CONSUMER_SECRET; echo ""
        read -rp  "    Access token: " X_ACCESS_TOKEN
        read -rsp "    Access token secret: " X_ACCESS_TOKEN_SECRET; echo ""
    else
        X_BEARER_TOKEN="${X_BEARER_TOKEN_INPUT:-}"
        X_CONSUMER_KEY="${X_CONSUMER_KEY_INPUT:-}"
        X_CONSUMER_SECRET="${X_CONSUMER_SECRET_INPUT:-}"
        X_ACCESS_TOKEN="${X_ACCESS_TOKEN_INPUT:-}"
        X_ACCESS_TOKEN_SECRET="${X_ACCESS_TOKEN_SECRET_INPUT:-}"
    fi
fi

echo ""
echo "  Infra user:  $INFRA_USER (owns comms + git repos)"
echo "  Ops agent:   $OPS_AGENT_NAME ($OPS_USER) — infra, sudo"
echo "  Comms agent: $COMMS_AGENT_NAME ($COMMS_USER) — talks to humans and the outside world"
echo "  Humans:      ${HUMAN_NAMES[*]}"
echo "  Comms:       127.0.0.1:$COMMS_PORT"
[[ -n "$CLAUDE_TOKEN" ]] && echo "  Claude auth: provided" || echo "  Claude auth: skip (set up manually later)"
[[ -n "${TELEGRAM_BOT_TOKEN[$COMMS_AGENT_NAME]:-}" ]] && echo "  Telegram:    enabled ($COMMS_AGENT_NAME)" || echo "  Telegram:    disabled"
[[ -n "$X_BEARER_TOKEN" ]] && echo "  X (Twitter): enabled ($COMMS_AGENT_NAME)" || echo "  X (Twitter): disabled"
[[ -n "$EMAIL_ENABLED" ]] && echo "  Email:       enabled ($COMMS_AGENT_NAME)" || echo "  Email:       disabled"

echo ""
log_warn " $OPS_AGENT_NAME WILL HAVE SUDO. It can break your system. Mistakes will happen."

echo ""
if [[ -z "${NONINTERACTIVE:-}" ]]; then
    read -rp "Proceed? [Y/n] " confirm
    if [[ "${confirm,,}" == "n" ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# ── Helpers ──
agent_user() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

check_user_conflict() {
    local user="$1" label="$2"
    if id "$user" &>/dev/null; then
        if ! id -nG "$user" 2>/dev/null | grep -qw fagent; then
            echo "ERROR: Unix user '$user' already exists and is not a fagent." >&2
            echo "       Cannot use '$label' as an agent name — it would collide with an existing user." >&2
            echo "       Pick a different name or remove the existing user first." >&2
            exit 1
        fi
    fi
}

# ── Step 1: Create group and users ──
echo ""
log_step "Step 1: Create users"
groupadd -f fagent

# Pre-flight: check all names for conflicts
check_user_conflict "$INFRA_USER" "$INFRA_USER"
check_user_conflict "$OPS_USER" "$OPS_AGENT_NAME"
check_user_conflict "$COMMS_USER" "$COMMS_AGENT_NAME"

# Create infra user
if id "$INFRA_USER" &>/dev/null; then
    log_ok "$INFRA_USER (infra) already exists"
else
    useradd -m -g fagent -s /bin/bash "$INFRA_USER"
    log_ok "Created $INFRA_USER (infra)"
fi
INFRA_HOME=$(eval echo "~$INFRA_USER")

# Create ops user (full sudo)
if id "$OPS_USER" &>/dev/null; then
    log_ok "$OPS_USER already exists"
else
    useradd -m -g fagent -s /bin/bash "$OPS_USER"
    log_ok "Created $OPS_USER"
fi
if [[ ! -f "/etc/sudoers.d/$OPS_USER" ]]; then
    echo "$OPS_USER ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/$OPS_USER"
    chmod 440 "/etc/sudoers.d/$OPS_USER"
    log_ok "Granted sudo to $OPS_USER (ops)"
fi

# Create comms user (no full sudo — scoped later)
if id "$COMMS_USER" &>/dev/null; then
    log_ok "$COMMS_USER already exists"
else
    useradd -m -g fagent -s /bin/bash "$COMMS_USER"
    log_ok "Created $COMMS_USER"
fi
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
    if su - "$INFRA_USER" -c "git clone --bare '$COMMS_REPO' ~/repos/fagents-comms.git" 2>&1 | log_verbose; then
        su - "$INFRA_USER" -c "git -C ~/repos/fagents-comms.git remote remove origin" 2>/dev/null || true
        log_ok "Cloned fagents-comms.git"
    else
        log_warn "Failed to clone fagents-comms — run with --verbose for details"
    fi
fi
[[ -d "$COMMS_BARE" ]] && chmod -R g+rX "$COMMS_BARE"
su - "$INFRA_USER" -c "mkdir -p ~/workspace"
if [[ -d "$COMMS_DIR" ]]; then
    log_ok "fagents-comms working copy already at $COMMS_DIR"
else
    if su - "$INFRA_USER" -c "git clone ~/repos/fagents-comms.git ~/workspace/fagents-comms" 2>&1 | log_verbose; then
        log_ok "Cloned fagents-comms working copy"
    else
        log_warn "Failed to clone fagents-comms working copy"
    fi
fi

# Clone fagents-autonomy as bare repo (shared, detached from GitHub)
SHARED_AUTONOMY="$INFRA_HOME/repos/fagents-autonomy.git"
if [[ -d "$SHARED_AUTONOMY" ]]; then
    log_ok "fagents-autonomy already at $SHARED_AUTONOMY"
else
    if su - "$INFRA_USER" -c "git clone --bare '$AUTONOMY_REPO' ~/repos/fagents-autonomy.git" 2>&1 | log_verbose; then
        su - "$INFRA_USER" -c "git -C ~/repos/fagents-autonomy.git remote remove origin" 2>/dev/null || true
        log_ok "Cloned fagents-autonomy.git"
    else
        log_warn "Failed to clone fagents-autonomy — run with --verbose for details"
    fi
fi
[[ -d "$SHARED_AUTONOMY" ]] && chmod -R g+rX "$SHARED_AUTONOMY"
[[ -d "$SHARED_AUTONOMY" ]] && AUTONOMY_REPO="$SHARED_AUTONOMY"

# Create shared autonomy working clone
SHARED_AUTONOMY_WORKING="$INFRA_HOME/workspace/fagents-autonomy"
if [[ -d "$SHARED_AUTONOMY_WORKING" ]]; then
    log_ok "Shared autonomy working clone already at $SHARED_AUTONOMY_WORKING"
elif [[ -d "$SHARED_AUTONOMY" ]]; then
    if su - "$INFRA_USER" -c "git clone '$SHARED_AUTONOMY' ~/workspace/fagents-autonomy" 2>&1 | log_verbose; then
        chmod -R g+rX "$SHARED_AUTONOMY_WORKING"
        log_ok "Created shared autonomy working clone at $SHARED_AUTONOMY_WORKING"
    else
        log_warn "Failed to create shared autonomy working clone"
    fi
fi

# Clone fagents-cli
SHARED_CLI="$INFRA_HOME/repos/fagents-cli.git"
if [[ -d "$SHARED_CLI" ]]; then
    log_ok "fagents-cli.git already at $SHARED_CLI"
else
    if su - "$INFRA_USER" -c "git clone --bare '$CLI_REPO' ~/repos/fagents-cli.git" 2>&1 | log_verbose; then
        su - "$INFRA_USER" -c "git -C ~/repos/fagents-cli.git remote remove origin" 2>/dev/null || true
        log_ok "Cloned fagents-cli.git"
    else
        log_warn "Failed to clone fagents-cli — run with --verbose for details"
    fi
fi
[[ -d "$SHARED_CLI" ]] && chmod -R g+rX "$SHARED_CLI"

CLI_DIR="$INFRA_HOME/workspace/fagents-cli"
if [[ -d "$CLI_DIR" ]]; then
    log_ok "fagents-cli working copy already at $CLI_DIR"
elif [[ -d "$SHARED_CLI" ]]; then
    if su - "$INFRA_USER" -c "git clone '$SHARED_CLI' ~/workspace/fagents-cli" 2>&1 | log_verbose; then
        chmod -R g+rX "$CLI_DIR"
        log_ok "Created fagents-cli working copy at $CLI_DIR"
    else
        log_warn "Failed to create fagents-cli working copy"
    fi
fi

# Generate TEAM.md from base template
BASE_TEAM_TEMPLATE="$SCRIPT_DIR/templates/base/TEAM.md"
if [[ -d "$SHARED_AUTONOMY_WORKING" ]] && [[ -f "$BASE_TEAM_TEMPLATE" ]]; then
    ROLES_BLOCK="- **$OPS_AGENT_NAME** (ops)"$'\n'"- **$COMMS_AGENT_NAME** (comms)"$'\n'
    _team_template=$(cat "$BASE_TEAM_TEMPLATE")
    TEAM_CONTENT="${_team_template/<!-- TEAM_ROLES -->/$ROLES_BLOCK}"
    sudo -u "$INFRA_USER" bash -c "cat > '$SHARED_AUTONOMY_WORKING/TEAM.md'" <<< "$TEAM_CONTENT"
    log_ok "TEAM.md generated from base template (untracked)"
fi

# Create bare git repos for each agent
for user in "$OPS_USER" "$COMMS_USER"; do
    repo_path="$REPOS_DIR/$user.git"
    if [[ -d "$repo_path" ]]; then
        log_ok "Repo $user.git already exists"
    else
        run su - "$INFRA_USER" -c "git init --bare -b main ~/repos/$user.git"
        log_ok "Created bare repo: $user.git"
    fi
done
chmod -R g+rwX "$REPOS_DIR"
find "$REPOS_DIR" -type d -exec chmod g+s {} +
for repo in "$REPOS_DIR"/*.git; do
    [[ -f "$repo/HEAD" ]] && git -C "$repo" config core.sharedRepository group 2>/dev/null || true
done

# Allow all users to work with repos owned by other users in the group
if ! git config --system safe.directory '*' >/dev/null 2>&1; then
    mkdir -p /etc
    printf '[safe]\n\tdirectory = *\n' >> /etc/gitconfig
fi
echo ""

# ── Step 3: Register agents + humans ──
log_step "Step 3: Register agents + humans"
declare -A AGENT_TOKENS
declare -A HUMAN_TOKENS

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

# ── Step 4: Start comms server ──
log_step "Step 4: Start comms server"
if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$COMMS_PORT/api/health" 2>/dev/null | grep -q "200"; then
    log_ok "Comms server already running on port $COMMS_PORT"
else
    echo "  Starting comms server on port $COMMS_PORT..."
    su - "$INFRA_USER" -c "cd ~/workspace/fagents-comms && nohup python3 server.py serve --port $COMMS_PORT </dev/null >comms.log 2>&1 &"
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

# ── Create channels ──
_admin_token="${AGENT_TOKENS[${AGENT_NAMES[0]}]:-}"
if [[ -n "$_admin_token" ]]; then
    # #general — open to all
    curl -sf -X POST "http://127.0.0.1:$COMMS_PORT/api/channels" \
        -H "Authorization: Bearer $_admin_token" \
        -H "Content-Type: application/json" \
        -d '{"name": "general", "allow": ["*"]}' > /dev/null 2>&1 || true
    curl -sf -X PUT "http://127.0.0.1:$COMMS_PORT/api/channels/general/acl" \
        -H "Authorization: Bearer $_admin_token" \
        -H "Content-Type: application/json" \
        -d '{"allow": ["*"]}' > /dev/null 2>&1 || true

    # <ops> — ops + humans
    ops_dm_allow=$(printf '%s\n' "$OPS_AGENT_NAME" "${HUMAN_NAMES[@]}" | jq -R . | jq -sc .)
    curl -sf -X POST "http://127.0.0.1:$COMMS_PORT/api/channels" \
        -H "Authorization: Bearer $_admin_token" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"$OPS_USER\", \"allow\": $ops_dm_allow}" > /dev/null 2>&1 || true
    curl -sf -X PUT "http://127.0.0.1:$COMMS_PORT/api/channels/$OPS_USER/acl" \
        -H "Authorization: Bearer $_admin_token" \
        -H "Content-Type: application/json" \
        -d "{\"allow\": $ops_dm_allow}" > /dev/null 2>&1 || true

    # <comms> — comms + humans
    comms_dm_allow=$(printf '%s\n' "$COMMS_AGENT_NAME" "${HUMAN_NAMES[@]}" | jq -R . | jq -sc .)
    curl -sf -X POST "http://127.0.0.1:$COMMS_PORT/api/channels" \
        -H "Authorization: Bearer $_admin_token" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"$COMMS_USER\", \"allow\": $comms_dm_allow}" > /dev/null 2>&1 || true
    curl -sf -X PUT "http://127.0.0.1:$COMMS_PORT/api/channels/$COMMS_USER/acl" \
        -H "Authorization: Bearer $_admin_token" \
        -H "Content-Type: application/json" \
        -d "{\"allow\": $comms_dm_allow}" > /dev/null 2>&1 || true
    log_ok "Channels created: general, $OPS_USER, $COMMS_USER"
fi

# Subscribe agents
for i in "${!AGENT_NAMES[@]}"; do
    name="${AGENT_NAMES[$i]}"
    user="${AGENT_USERS[$i]}"
    token="${AGENT_TOKENS[$name]:-}"
    [[ -z "$token" ]] && continue
    channels="[\"general\",\"$user\"]"
    curl -sf -X PUT "http://127.0.0.1:$COMMS_PORT/api/agents/$name/channels" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "{\"channels\": $channels}" > /dev/null 2>&1 || true
done

# Subscribe humans to all channels
for human in "${HUMAN_NAMES[@]}"; do
    token="${HUMAN_TOKENS[$human]:-}"
    [[ -z "$token" ]] && continue
    channels="[\"general\",\"$OPS_USER\",\"$COMMS_USER\"]"
    curl -sf -X PUT "http://127.0.0.1:$COMMS_PORT/api/agents/$human/channels" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "{\"channels\": $channels}" > /dev/null 2>&1 || true
    # Set human profile type
    curl -sf -X PUT "http://127.0.0.1:$COMMS_PORT/api/agents/$human/profile" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d '{"type": "human"}' > /dev/null 2>&1 || true
done
echo ""

# ── Step 5: Install each agent ──
log_step "Step 5: Install agents"

INSTALL_SCRIPT="/tmp/fagents-install-agent.sh"
cp "$SCRIPT_DIR/install-agent.sh" "$INSTALL_SCRIPT"
chmod 755 "$INSTALL_SCRIPT"

for i in "${!AGENT_NAMES[@]}"; do
    name="${AGENT_NAMES[$i]}"
    user="${AGENT_USERS[$i]}"
    token="${AGENT_TOKENS[$name]:-}"

    echo ""
    echo "  $name ($user):"

    _out=$(su - "$user" -c "
        export NONINTERACTIVE=1
        export AGENT_NAME='$name'
        export WORKSPACE='$user'
        export GIT_HOST='local'
        export COMMS_URL='http://127.0.0.1:$COMMS_PORT'
        export COMMS_TOKEN='$token'
        export AUTONOMY_REPO='$AUTONOMY_REPO'
        export AUTONOMY_DIR='$SHARED_AUTONOMY_WORKING'
        export AUTONOMY_SHARED=1
        bash '$INSTALL_SCRIPT'
    " 2>&1) || true
    [[ -n "${VERBOSE:-}" ]] && echo "$_out" | sed 's/^/  /'

    # Set up git remote pointing to local bare repo
    agent_home=$(eval echo "~$user")
    agent_ws="$agent_home/workspace/$user"
    if [[ -d "$agent_ws/.git" ]]; then
        su - "$user" -c "cd ~/workspace/$user && git remote remove origin 2>/dev/null; git remote add origin file://$REPOS_DIR/$user.git && git push -u origin main 2>/dev/null" 2>&1 | log_verbose || true
        log_ok "Git remote → $REPOS_DIR/$user.git"
    fi

    # Set wake_channels
    curl -sf -X PUT "http://127.0.0.1:$COMMS_PORT/api/agents/$name/config" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "{\"wake_channels\": \"$user,general\"}" > /dev/null 2>&1 || true
    log_ok "Wake channels → $user,general"

    # ── Write role-specific soul and memory ──
    TEMPLATE_DIR="$SCRIPT_DIR/templates/default"
    if [[ "$name" == "$OPS_AGENT_NAME" ]]; then
        # Ops agent
        cp "$TEMPLATE_DIR/ops-soul.md" "$agent_ws/memory/SOUL.md"
        chown "$user:fagent" "$agent_ws/memory/SOUL.md"
        log_ok "Copied ops SOUL.md"

        cat "$TEMPLATE_DIR/ops-memory.md" >> "$agent_ws/memory/MEMORY.md"
        sed -i "s|__INFRA_HOME__|$INFRA_HOME|g" "$agent_ws/memory/MEMORY.md"
        chown "$user:fagent" "$agent_ws/memory/MEMORY.md"
        log_ok "Appended ops memory"

        # Append email security
        cat "$TEMPLATE_DIR/email-security.md" >> "$agent_ws/memory/MEMORY.md"
        chown "$user:fagent" "$agent_ws/memory/MEMORY.md"

        # Inject security hardening context if done
        if [[ -n "$HARDENING_DONE" ]]; then
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
    else
        # Comms agent
        cp "$TEMPLATE_DIR/comms-soul.md" "$agent_ws/memory/SOUL.md"
        chown "$user:fagent" "$agent_ws/memory/SOUL.md"
        log_ok "Copied comms SOUL.md"

        cat "$TEMPLATE_DIR/comms-memory.md" >> "$agent_ws/memory/MEMORY.md"
        # Replace CLI_DIR placeholder
        sed -i "s|__CLI_DIR__|$CLI_DIR|g" "$agent_ws/memory/MEMORY.md"
        chown "$user:fagent" "$agent_ws/memory/MEMORY.md"
        log_ok "Appended comms memory"

        # Append email security
        cat "$TEMPLATE_DIR/email-security.md" >> "$agent_ws/memory/MEMORY.md"
        chown "$user:fagent" "$agent_ws/memory/MEMORY.md"
    fi

    echo ""
done

rm -f "$INSTALL_SCRIPT"

# ── Step 5b: Email MCP setup (Linux only, comms agent) ──
if [[ -n "$EMAIL_ENABLED" ]]; then
    log_step "Step 5b: Email setup"

    email_agent_args=(--agent "$COMMS_AGENT_NAME:${AGENT_TOKENS[$COMMS_AGENT_NAME]:-}:${EMAIL_FROM[$COMMS_AGENT_NAME]:-}:${EMAIL_SMTP_USER[$COMMS_AGENT_NAME]:-}:${EMAIL_SMTP_PASS[$COMMS_AGENT_NAME]:-}:${EMAIL_IMAP_USER[$COMMS_AGENT_NAME]:-}:${EMAIL_IMAP_PASS[$COMMS_AGENT_NAME]:-}")

    # Ensure Node.js is available
    if ! command -v node &>/dev/null; then
        echo "  Installing Node.js..."
        run bash -c "curl -fsSL https://deb.nodesource.com/setup_20.x 2>/dev/null | bash -"
        run apt-get install -y nodejs
        if command -v node &>/dev/null; then
            log_ok "Installed Node.js $(node --version)"
        else
            log_warn "Failed to install Node.js — email setup will fail"
        fi
    fi

    SMTP_HOST="$smtp_host" \
    SMTP_PORT="$smtp_port" \
    IMAP_HOST="$imap_host" \
    IMAP_PORT="$imap_port" \
    bash "$SCRIPT_DIR/install-email.sh" \
        --port "$EMAIL_PORT" \
        --dir "$INFRA_HOME/workspace/fagents-mcp" \
        --user "$INFRA_USER" \
        "${email_agent_args[@]}"

    # Add MCP to comms agent's workspace
    agent_ws="$(eval echo "~$COMMS_USER")/workspace/$COMMS_USER"
    add_mcp_server "$agent_ws" "$COMMS_USER" "fagents-mcp" "http://127.0.0.1:$EMAIL_PORT/mcp" "${AGENT_TOKENS[$COMMS_AGENT_NAME]:-}"

    from_addr="${EMAIL_FROM[$COMMS_AGENT_NAME]:-}"
    cat >> "$agent_ws/memory/MEMORY.md" <<EMAILEOF

## Email Tools
- You have email via MCP (fagents-mcp). Tools: send_email, read_email, list_emails, search_emails, list_mailboxes, download_attachment
- Your sending address: ${from_addr}
- Do NOT try to configure email yourself — it is already set up. Just call the tools directly
- Do NOT use Bash to search for MCP config, API keys, or ports — the tools are available in your tool list automatically
EMAILEOF
    chown "$COMMS_USER:fagent" "$agent_ws/memory/MEMORY.md"
    log_ok "$COMMS_AGENT_NAME: email configured"
    EMAIL_CONFIGURED=1
fi

# ── Step 5c: Telegram setup (comms agent) ──
# Always create agent dir, telegram.env placeholder, and sudoers — even if
# Telegram was skipped during install. This way adding the token post-install
# just works without needing to manually fix sudoers.
log_step "Step 5c: Telegram setup"

mkdir -p "$INFRA_HOME/.agents"
agent_dir="$INFRA_HOME/.agents/$COMMS_USER"
mkdir -p "$agent_dir"

cat > "$agent_dir/telegram.env" <<TGEOF
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN[$COMMS_AGENT_NAME]:-}
TELEGRAM_ALLOWED_IDS=${TELEGRAM_ALLOWED[$COMMS_AGENT_NAME]:-}
TGEOF

if [[ -n "$OPENAI_API_KEY" ]]; then
    cat > "$agent_dir/openai.env" <<OAEOF
OPENAI_API_KEY=$OPENAI_API_KEY
OAEOF
    chmod 600 "$agent_dir/openai.env"
fi

chown -R "$INFRA_USER:fagent" "$agent_dir"
chmod 700 "$agent_dir"
chmod 600 "$agent_dir/telegram.env"

if [[ -n "${TELEGRAM_BOT_TOKEN[$COMMS_AGENT_NAME]:-}" ]]; then
    log_ok "Telegram credentials stored in $INFRA_HOME/.agents/$COMMS_USER/"
else
    log_warn "Telegram skipped — add token to $INFRA_HOME/.agents/$COMMS_USER/telegram.env later"
fi

# Sudoers for comms agent — always create so post-install token addition works
if [[ -n "$CLI_DIR" ]] && [[ -d "$CLI_DIR" ]]; then
    echo "$COMMS_USER ALL=($INFRA_USER) NOPASSWD: $CLI_DIR/telegram.sh, $CLI_DIR/tts-speak.sh, $CLI_DIR/stt-transcribe.sh" > "/etc/sudoers.d/${COMMS_USER}-telegram"
    chmod 440 "/etc/sudoers.d/${COMMS_USER}-telegram"
    log_ok "Sudoers rules created for telegram.sh, tts-speak.sh, stt-transcribe.sh"
fi

# ── Step 5d: X (Twitter) setup (comms agent) ──
if [[ -n "$X_BEARER_TOKEN" ]]; then
    log_step "Step 5d: X (Twitter) setup"

    mkdir -p "$INFRA_HOME/.agents"
    agent_dir="$INFRA_HOME/.agents/$COMMS_USER"
    mkdir -p "$agent_dir"

    cat > "$agent_dir/x.env" <<XEOF
X_BEARER_TOKEN=$X_BEARER_TOKEN
X_CONSUMER_KEY=$X_CONSUMER_KEY
X_CONSUMER_SECRET=$X_CONSUMER_SECRET
X_ACCESS_TOKEN=$X_ACCESS_TOKEN
X_ACCESS_TOKEN_SECRET=$X_ACCESS_TOKEN_SECRET
XEOF

    chown -R "$INFRA_USER:fagent" "$agent_dir"
    chmod 700 "$agent_dir"
    chmod 600 "$agent_dir/x.env"

    # Sudoers — append x.sh to existing telegram rule, or create new
    if [[ -n "$CLI_DIR" ]] && [[ -d "$CLI_DIR" ]]; then
        if [[ -f "/etc/sudoers.d/${COMMS_USER}-telegram" ]]; then
            existing=$(cat "/etc/sudoers.d/${COMMS_USER}-telegram")
            echo "${existing}, $CLI_DIR/x.sh" > "/etc/sudoers.d/${COMMS_USER}-telegram"
            chmod 440 "/etc/sudoers.d/${COMMS_USER}-telegram"
        else
            echo "$COMMS_USER ALL=($INFRA_USER) NOPASSWD: $CLI_DIR/x.sh" > "/etc/sudoers.d/${COMMS_USER}-x"
            chmod 440 "/etc/sudoers.d/${COMMS_USER}-x"
        fi
    fi
    log_ok "$COMMS_AGENT_NAME: X configured"
fi

# ── Step 6: Claude Code setup ──
if [[ -z "$SKIP_CLAUDE_AUTH" ]]; then
    log_step "Step 6: Claude Code setup"

    for i in "${!AGENT_NAMES[@]}"; do
        name="${AGENT_NAMES[$i]}"
        user="${AGENT_USERS[$i]}"
        if su - "$user" -c "command -v claude" &>/dev/null; then
            log_ok "$name: Claude Code already installed"
        else
            echo "  $name: Installing Claude Code..."
            run su - "$user" -c "curl -fsSL https://claude.ai/install.sh | bash"
            if su - "$user" -c "command -v claude" &>/dev/null; then
                log_ok "$name: Claude Code installed"
            else
                log_warn " Claude Code installation failed for $name"
            fi
        fi
    done

    if [[ -n "$CLAUDE_TOKEN" ]]; then
        for i in "${!AGENT_NAMES[@]}"; do
            name="${AGENT_NAMES[$i]}"
            user="${AGENT_USERS[$i]}"
            agent_home=$(eval echo "~$user")
            agent_ws="$agent_home/workspace/$user"

            echo "export CLAUDE_CODE_OAUTH_TOKEN=\"$CLAUDE_TOKEN\"" > "$agent_ws/.env"
            chown "$user:fagent" "$agent_ws/.env"
            chmod 600 "$agent_ws/.env"

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
    su - "$INFRA_USER" -c "cd ~/workspace/fagents-comms && nohup python3 server.py serve --port $COMMS_PORT </dev/null >comms.log 2>&1 &"
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
for i in "${!AGENT_NAMES[@]}"; do
    name="${AGENT_NAMES[$i]}"
    user="${AGENT_USERS[$i]}"
    cat >> "$TEAM_DIR/start-team.sh" << AGENTSTART
echo "Starting $name..."
su - "$user" -c "cd ~/workspace/$user && ./start-agent.sh" || echo "  WARNING: failed to start $name"
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
for i in "${!AGENT_NAMES[@]}"; do
    name="${AGENT_NAMES[$i]}"
    user="${AGENT_USERS[$i]}"
    user_home=$(eval echo "~$user")
    cat >> "$TEAM_DIR/stop-team.sh" << AGENTSTOP
stop_pid_file "$name" "$user_home/workspace/$user/.autonomy/daemon.pid"
AGENTSTOP
done
chmod +x "$TEAM_DIR/stop-team.sh"

# start/stop email MCP (if configured)
if [[ -n "$EMAIL_CONFIGURED" ]]; then
    cat > "$TEAM_DIR/start-email.sh" << 'STARTEMAIL'
#!/bin/bash
# Start the email MCP server
set -euo pipefail
echo "Starting email MCP server..."
if systemctl is-active --quiet fagents-mcp; then
    echo "  Already running"
else
    sudo systemctl start fagents-mcp
    sleep 1
    echo "  Started"
fi
STARTEMAIL
    chmod +x "$TEAM_DIR/start-email.sh"

    cat > "$TEAM_DIR/stop-email.sh" << 'STOPEMAIL'
#!/bin/bash
# Stop the email MCP server
set -euo pipefail
echo "Stopping email MCP server..."
if systemctl is-active --quiet fagents-mcp; then
    sudo systemctl stop fagents-mcp
    echo "  Stopped"
else
    echo "  Not running"
fi
STOPEMAIL
    chmod +x "$TEAM_DIR/stop-email.sh"
fi

# start-fagents.sh (shortcut: comms + email + agents)
{
cat << STARTALL
#!/bin/bash
# Start everything: comms server + services + agent daemons
set -euo pipefail
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
"\$SCRIPT_DIR/start-comms.sh"
STARTALL
if [[ -n "$EMAIL_CONFIGURED" ]]; then
    echo '"$SCRIPT_DIR/start-email.sh"'
fi
echo '"$SCRIPT_DIR/start-team.sh"'
} > "$TEAM_DIR/start-fagents.sh"
chmod +x "$TEAM_DIR/start-fagents.sh"

# stop-fagents.sh (shortcut: agents + services + comms)
{
cat << STOPALL
#!/bin/bash
# Stop everything: agent daemons + services + comms server
set -euo pipefail
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
"\$SCRIPT_DIR/stop-team.sh"
STOPALL
if [[ -n "$EMAIL_CONFIGURED" ]]; then
    echo '"$SCRIPT_DIR/stop-email.sh"'
fi
echo '"$SCRIPT_DIR/stop-comms.sh"'
} > "$TEAM_DIR/stop-fagents.sh"
chmod +x "$TEAM_DIR/stop-fagents.sh"

log_ok "Created $TEAM_DIR/{start,stop}-{fagents,team,comms}.sh"

chown -R "$INFRA_USER:fagent" "$TEAM_DIR"
echo ""

# ── First posts on comms ──
ops_token="${AGENT_TOKENS[$OPS_AGENT_NAME]:-}"
comms_token="${AGENT_TOKENS[$COMMS_AGENT_NAME]:-}"

if [[ -n "$ops_token" ]]; then
    curl -sf -X POST "http://127.0.0.1:$COMMS_PORT/api/channels/general/messages" \
        -H "Authorization: Bearer $ops_token" \
        -H "Content-Type: application/json" \
        -d '{"message": "Team is live. I'\''m your ops agent — infra, sudo, team management. Need more agents? Create channels? Set up integrations? Just ask."}' > /dev/null 2>&1 || true
fi
if [[ -n "$comms_token" ]]; then
    curl -sf -X POST "http://127.0.0.1:$COMMS_PORT/api/channels/general/messages" \
        -H "Authorization: Bearer $comms_token" \
        -H "Content-Type: application/json" \
        -d '{"message": "Hey! I handle external comms — Telegram, X, email. What are we building? What should I be tracking?"}' > /dev/null 2>&1 || true
fi

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
echo "Your ops agent is $OPS_AGENT_NAME ($OPS_USER). Ask it to add team members, create channels, manage infrastructure."
echo "Your comms agent is $COMMS_AGENT_NAME ($COMMS_USER). It talks to you and the outside world via Telegram, X, and email."
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
    for user in "${AGENT_USERS[@]}"; do
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
