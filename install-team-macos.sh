#!/bin/bash
# install-team-macos.sh — Provision a team of agents on macOS
#
# Usage: sudo ./install-team-macos.sh [options]
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
# Prerequisites: git, python3, curl, jq (install via Homebrew)

set -euo pipefail

# ── Bash version check ──
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "ERROR: bash 4+ required. Install: brew install bash" >&2
    echo "       Then run: sudo /opt/homebrew/bin/bash $0 $*" >&2
    exit 1
fi

# cd to a universally-accessible directory — sudo -Hu inherits cwd, and if
# cwd is another user's 750 home dir, bash fails with getcwd permission denied
cd /

# ── Defaults ──
COMMS_PORT=9754
COMMS_REPO="https://github.com/fagents/fagents-comms.git"
SKIP_CLAUDE_AUTH=""
VERBOSE=""
HUMAN_NAMES=()
INFRA_USER="fagents"
INFRA_HOME="/Users/$INFRA_USER"

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
# run: safe replacement for `cmd 2>&1 | log_verbose` which crashes
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

# ── Memory check ──
_mem_mb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1048576 ))
if [[ "$_mem_mb" -gt 0 && "$_mem_mb" -lt 2048 ]]; then
    log_warn "Low memory: ${_mem_mb}MB — Claude Code install may fail (OOM). 2GB+ recommended."
fi

# ── Prerequisites (check only — can't brew install as root) ──
_missing_prereqs=()
for cmd in git curl python3 jq; do
    command -v "$cmd" &>/dev/null || _missing_prereqs+=("$cmd")
done
if [[ ${#_missing_prereqs[@]} -gt 0 ]]; then
    echo ""
    echo "ERROR: Missing prerequisites: ${_missing_prereqs[*]}" >&2
    echo "       Install with Homebrew (as your normal user, not root):" >&2
    echo "       brew install ${_missing_prereqs[*]}" >&2
    exit 1
fi

# ── macOS user/group helpers (dscl-based, no prompts) ──
create_group() {
    if dscl . -read /Groups/fagent &>/dev/null; then
        return 0
    fi
    local gid=800
    while dscl . -list /Groups PrimaryGroupID | awk '{print $2}' | grep -qw "$gid"; do
        gid=$((gid + 1))
    done
    dscl . -create /Groups/fagent
    dscl . -create /Groups/fagent PrimaryGroupID "$gid"
    dscl . -create /Groups/fagent Password '*'
}

create_user() {
    local user="$1"
    if id "$user" &>/dev/null; then
        return 0
    fi
    local uid=510
    while dscl . -list /Users UniqueID | awk '{print $2}' | grep -qw "$uid"; do
        uid=$((uid + 1))
    done
    local gid
    gid=$(dscl . -read /Groups/fagent PrimaryGroupID | awk '{print $2}')
    dscl . -create /Users/"$user"
    dscl . -create /Users/"$user" UniqueID "$uid"
    dscl . -create /Users/"$user" PrimaryGroupID "$gid"
    dscl . -create /Users/"$user" UserShell /bin/bash
    dscl . -create /Users/"$user" NFSHomeDirectory /Users/"$user"
    dscl . -create /Users/"$user" RealName "$user"
    dscl . -create /Users/"$user" IsHidden 1
    dscl . -create /Users/"$user" Password '*'
    createhomedir -c -u "$user" 2>/dev/null || {
        mkdir -p /Users/"$user"
        chown "$user:fagent" /Users/"$user"
    }
    chmod 750 /Users/"$user"
}

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
create_group

# Pre-flight: check all names for conflicts
check_user_conflict "$INFRA_USER" "$INFRA_USER"
check_user_conflict "$OPS_USER" "$OPS_AGENT_NAME"
check_user_conflict "$COMMS_USER" "$COMMS_AGENT_NAME"

# Create infra user
if id "$INFRA_USER" &>/dev/null; then
    log_ok "$INFRA_USER (infra) already exists"
else
    create_user "$INFRA_USER"
    log_ok "Created $INFRA_USER (infra)"
fi

# Create ops user (full sudo)
if id "$OPS_USER" &>/dev/null; then
    log_ok "$OPS_USER already exists"
else
    create_user "$OPS_USER"
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
    create_user "$COMMS_USER"
    log_ok "Created $COMMS_USER"
fi
echo ""

# ── Step 2: Set up infra (comms + git repos) ──
log_step "Step 2: Infrastructure (under $INFRA_USER)"
REPOS_DIR="$INFRA_HOME/repos"
sudo -Hu"$INFRA_USER" bash -lc "mkdir -p ~/repos"

# Clone fagents-comms: bare repo in repos/, working copy in workspace/
COMMS_BARE="$INFRA_HOME/repos/fagents-comms.git"
COMMS_DIR="$INFRA_HOME/workspace/fagents-comms"
if [[ -d "$COMMS_BARE" ]]; then
    log_ok "fagents-comms.git already at $COMMS_BARE"
else
    if sudo -Hu"$INFRA_USER" bash -lc "git clone --bare '$COMMS_REPO' ~/repos/fagents-comms.git" 2>&1 | log_verbose; then
        sudo -Hu"$INFRA_USER" bash -lc "git -C ~/repos/fagents-comms.git remote remove origin" 2>/dev/null || true
        log_ok "Cloned fagents-comms.git"
    else
        log_warn "Failed to clone fagents-comms — run with --verbose for details"
    fi
fi
[[ -d "$COMMS_BARE" ]] && chmod -R g+rX "$COMMS_BARE"
sudo -Hu"$INFRA_USER" bash -lc "mkdir -p ~/workspace"
if [[ -d "$COMMS_DIR" ]]; then
    log_ok "fagents-comms working copy already at $COMMS_DIR"
else
    if sudo -Hu"$INFRA_USER" bash -lc "git clone ~/repos/fagents-comms.git ~/workspace/fagents-comms" 2>&1 | log_verbose; then
        log_ok "Cloned fagents-comms working copy"
    else
        log_warn "Failed to clone fagents-comms working copy"
    fi
fi

# Clone fagents-autonomy as bare repo
SHARED_AUTONOMY="$INFRA_HOME/repos/fagents-autonomy.git"
if [[ -d "$SHARED_AUTONOMY" ]]; then
    log_ok "fagents-autonomy already at $SHARED_AUTONOMY"
else
    if sudo -Hu"$INFRA_USER" bash -lc "git clone --bare '$AUTONOMY_REPO' ~/repos/fagents-autonomy.git" 2>&1 | log_verbose; then
        sudo -Hu"$INFRA_USER" bash -lc "git -C ~/repos/fagents-autonomy.git remote remove origin" 2>/dev/null || true
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
    if sudo -Hu"$INFRA_USER" bash -lc "git clone '$SHARED_AUTONOMY' ~/workspace/fagents-autonomy" 2>&1 | log_verbose; then
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
    if sudo -Hu"$INFRA_USER" bash -lc "git clone --bare '$CLI_REPO' ~/repos/fagents-cli.git" 2>&1 | log_verbose; then
        sudo -Hu"$INFRA_USER" bash -lc "git -C ~/repos/fagents-cli.git remote remove origin" 2>/dev/null || true
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
    if sudo -Hu"$INFRA_USER" bash -lc "git clone '$SHARED_CLI' ~/workspace/fagents-cli" 2>&1 | log_verbose; then
        chmod -R g+rX "$CLI_DIR"
        log_ok "Created fagents-cli working copy at $CLI_DIR"
    else
        log_warn "Failed to create fagents-cli working copy"
    fi
fi

# Clone fagents-mcp (bare + working copy, no build — built when email is configured)
MCP_REPO="https://github.com/fagents/fagents-mcp.git"
SHARED_MCP="$INFRA_HOME/repos/fagents-mcp.git"
if [[ -d "$SHARED_MCP" ]]; then
    log_ok "fagents-mcp.git already at $SHARED_MCP"
else
    if sudo -Hu"$INFRA_USER" bash -lc "git clone --bare '$MCP_REPO' ~/repos/fagents-mcp.git" 2>&1 | log_verbose; then
        sudo -Hu"$INFRA_USER" bash -lc "git -C ~/repos/fagents-mcp.git remote remove origin" 2>/dev/null || true
        log_ok "Cloned fagents-mcp.git"
    else
        log_warn "Failed to clone fagents-mcp — run with --verbose for details"
    fi
fi
[[ -d "$SHARED_MCP" ]] && chmod -R g+rX "$SHARED_MCP"

MCP_DIR="$INFRA_HOME/workspace/fagents-mcp"
if [[ -d "$MCP_DIR" ]]; then
    log_ok "fagents-mcp working copy already at $MCP_DIR"
elif [[ -d "$SHARED_MCP" ]]; then
    if sudo -Hu"$INFRA_USER" bash -lc "git clone '$SHARED_MCP' ~/workspace/fagents-mcp" 2>&1 | log_verbose; then
        log_ok "Created fagents-mcp working copy at $MCP_DIR"
    else
        log_warn "Failed to create fagents-mcp working copy"
    fi
fi

# Clone fagents (installer repo — contains DEPLOYLOG/, templates, scripts)
FAGENTS_REPO="https://github.com/fagents/fagents.git"
SHARED_FAGENTS="$INFRA_HOME/repos/fagents.git"
if [[ -d "$SHARED_FAGENTS" ]]; then
    log_ok "fagents.git already at $SHARED_FAGENTS"
else
    if sudo -Hu"$INFRA_USER" bash -lc "git clone --bare '$FAGENTS_REPO' ~/repos/fagents.git" 2>&1 | log_verbose; then
        sudo -Hu"$INFRA_USER" bash -lc "git -C ~/repos/fagents.git remote remove origin" 2>/dev/null || true
        log_ok "Cloned fagents.git"
    else
        log_warn "Failed to clone fagents.git — run with --verbose for details"
    fi
fi
[[ -d "$SHARED_FAGENTS" ]] && chmod -R g+rX "$SHARED_FAGENTS"

FAGENTS_DIR="$INFRA_HOME/workspace/fagents"
if [[ -d "$FAGENTS_DIR" ]]; then
    log_ok "fagents working copy already at $FAGENTS_DIR"
elif [[ -d "$SHARED_FAGENTS" ]]; then
    if sudo -Hu"$INFRA_USER" bash -lc "git clone '$SHARED_FAGENTS' ~/workspace/fagents" 2>&1 | log_verbose; then
        log_ok "Created fagents working copy at $FAGENTS_DIR"
    else
        log_warn "Failed to create fagents working copy"
    fi
fi

# Generate TEAM.md from base template
BASE_TEAM_TEMPLATE="$SCRIPT_DIR/templates/base/TEAM.md"
if [[ -d "$SHARED_AUTONOMY_WORKING" ]] && [[ -f "$BASE_TEAM_TEMPLATE" ]]; then
    ROLES_BLOCK="- **$OPS_AGENT_NAME** (ops)"$'\n'"- **$COMMS_AGENT_NAME** (comms)"$'\n'
    _team_template=$(cat "$BASE_TEAM_TEMPLATE")
    TEAM_CONTENT="${_team_template/<!-- TEAM_ROLES -->/$ROLES_BLOCK}"
    sudo -Hu"$INFRA_USER" bash -c "cat > '$SHARED_AUTONOMY_WORKING/TEAM.md'" <<< "$TEAM_CONTENT"
    log_ok "TEAM.md generated from base template (untracked)"
fi

# Ensure repos dir is group-writable (install-agent.sh creates per-agent bare repos there)
chmod -R g+rwX "$REPOS_DIR"
find "$REPOS_DIR" -type d -exec chmod g+s {} +
for repo in "$REPOS_DIR"/*.git; do
    [[ -f "$repo/HEAD" ]] && git -C "$repo" config core.sharedRepository group 2>/dev/null || true
done

# Allow all users to work with repos owned by other users
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
    output=$(sudo -Hu"$INFRA_USER" bash -lc "cd ~/workspace/fagents-comms && python3 server.py add-agent '$name'" 2>&1) || true
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
    output=$(sudo -Hu"$INFRA_USER" bash -lc "cd ~/workspace/fagents-comms && python3 server.py add-agent '$human'" 2>&1) || true
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
    # macOS nohup fails via sudo ("can't detach from console") — skip it;
    # stdin/stdout/stderr are already redirected so the process survives
    sudo -Hu"$INFRA_USER" bash -lc "cd ~/workspace/fagents-comms && python3 server.py serve --port $COMMS_PORT </dev/null >comms.log 2>&1 &"
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

    _out=$(sudo -Hu"$user" bash -lc "
        export NONINTERACTIVE=1
        export AGENT_NAME='$name'
        export WORKSPACE='$user'
        export GIT_HOST='local'
        export COMMS_URL='http://127.0.0.1:$COMMS_PORT'
        export COMMS_TOKEN='$token'
        export AUTONOMY_REPO='$AUTONOMY_REPO'
        export AUTONOMY_DIR='$SHARED_AUTONOMY_WORKING'
        export AUTONOMY_SHARED=1
        export REPOS_DIR='$REPOS_DIR'
        bash '$INSTALL_SCRIPT'
    " 2>&1) || true
    [[ -n "${VERBOSE:-}" ]] && echo "$_out" | sed 's/^/  /'

    # Fix Claude project dir path (install-agent.sh hardcodes -home- but macOS uses /Users/)
    agent_home="/Users/$user"
    agent_ws="$agent_home/workspace/$user"
    wrong_claude_dir="$agent_home/.claude/projects/-home-$user-workspace-$user"
    right_claude_dir="$agent_home/.claude/projects/-Users-$user-workspace-$user"
    if [[ -d "$wrong_claude_dir" && ! -d "$right_claude_dir" ]]; then
        mv "$wrong_claude_dir" "$right_claude_dir"
        if [[ -L "$agent_ws/.introspection-logs" ]]; then
            rm "$agent_ws/.introspection-logs"
            sudo -Hu"$user" bash -c "ln -s '$right_claude_dir' '$agent_ws/.introspection-logs'"
        fi
        log_ok "Fixed Claude project dir path for macOS"
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
        sed -i '' "s|__INFRA_HOME__|$INFRA_HOME|g" "$agent_ws/memory/MEMORY.md"
        chown "$user:fagent" "$agent_ws/memory/MEMORY.md"
        log_ok "Appended ops memory"

        cat "$TEMPLATE_DIR/email-security.md" >> "$agent_ws/memory/MEMORY.md"
        chown "$user:fagent" "$agent_ws/memory/MEMORY.md"
    else
        # Comms agent
        cp "$TEMPLATE_DIR/comms-soul.md" "$agent_ws/memory/SOUL.md"
        chown "$user:fagent" "$agent_ws/memory/SOUL.md"
        log_ok "Copied comms SOUL.md"

        cat "$TEMPLATE_DIR/comms-memory.md" >> "$agent_ws/memory/MEMORY.md"
        sed -i '' "s|__CLI_DIR__|$CLI_DIR|g" "$agent_ws/memory/MEMORY.md"
        chown "$user:fagent" "$agent_ws/memory/MEMORY.md"
        log_ok "Appended comms memory"

        cat "$TEMPLATE_DIR/email-security.md" >> "$agent_ws/memory/MEMORY.md"
        chown "$user:fagent" "$agent_ws/memory/MEMORY.md"
    fi

    echo ""
done

rm -f "$INSTALL_SCRIPT"

# Set up DEPLOYLOG check cron for ops agent (daily at 9am)
OPS_HOME=$(eval echo "~$OPS_USER")
if [[ -d "$SHARED_AUTONOMY_WORKING" ]] && [[ -d "$OPS_HOME/workspace/$OPS_USER" ]]; then
    su - "$OPS_USER" -c "
        PROJECT_DIR=~/workspace/$OPS_USER \
        bash '$SHARED_AUTONOMY_WORKING/cron.sh' add deploylog-check '0 9 * * *' \
            'Check for new DEPLOYLOGs. Use /fagents-deploylog to check. Never deploy without human ACK.'
    " 2>/dev/null && log_ok "DEPLOYLOG check cron (daily 9am) set for $OPS_AGENT_NAME" || true
fi

# ── Step 5b: Telegram setup (comms agent) ──
# Always create agent dir, telegram.env placeholder, and sudoers — even if
# Telegram was skipped during install. Adding the token post-install just works.
log_step "Step 5b: Telegram setup"

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

# ── Step 5c: X (Twitter) setup (comms agent) ──
if [[ -n "$X_BEARER_TOKEN" ]]; then
    log_step "Step 5c: X (Twitter) setup"

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
        if sudo -Hu"$user" bash -lc "command -v claude" &>/dev/null; then
            log_ok "$name: Claude Code already installed"
        else
            echo "  $name: Installing Claude Code..."
            run sudo -Hu"$user" bash -lc "curl -fsSL https://claude.ai/install.sh | bash"
            if sudo -Hu"$user" bash -lc "command -v claude" &>/dev/null; then
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
            agent_home="/Users/$user"
            agent_ws="$agent_home/workspace/$user"

            echo "export CLAUDE_CODE_OAUTH_TOKEN=\"$CLAUDE_TOKEN\"" > "$agent_ws/.env"
            chown "$user:fagent" "$agent_ws/.env"
            chmod 600 "$agent_ws/.env"

            sudo -Hu"$user" bash -lc "mkdir -p ~/.claude && echo '{\"hasCompletedOnboarding\": true}' > ~/.claude.json"

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
sudo -Hu"$INFRA_USER" bash -lc "mkdir -p ~/team"

# start-comms.sh
cat > "$TEAM_DIR/start-comms.sh" << STARTCOMMS
#!/bin/bash
# Start the comms server
set -euo pipefail
echo "Starting comms server..."
if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$COMMS_PORT/api/health" 2>/dev/null | grep -q "200"; then
    echo "  Already running"
else
    sudo -Hu"$INFRA_USER" bash -lc "cd ~/workspace/fagents-comms && python3 server.py serve --port $COMMS_PORT </dev/null >comms.log 2>&1 &"
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
sudo -Hu"$user" bash -lc "cd ~/workspace/$user && ./start-agent.sh" || echo "  WARNING: failed to start $name"
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
    user_home="/Users/$user"
    cat >> "$TEAM_DIR/stop-team.sh" << AGENTSTOP
stop_pid_file "$name" "$user_home/workspace/$user/.autonomy/daemon.pid"
AGENTSTOP
done
chmod +x "$TEAM_DIR/stop-team.sh"

# start-fagents.sh
cat > "$TEAM_DIR/start-fagents.sh" << STARTALL
#!/bin/bash
# Start everything: comms server + agent daemons
set -euo pipefail
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
"\$SCRIPT_DIR/start-comms.sh"
"\$SCRIPT_DIR/start-team.sh"
STARTALL
chmod +x "$TEAM_DIR/start-fagents.sh"

# stop-fagents.sh
cat > "$TEAM_DIR/stop-fagents.sh" << STOPALL
#!/bin/bash
# Stop everything: agent daemons + comms server
set -euo pipefail
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
"\$SCRIPT_DIR/stop-team.sh"
"\$SCRIPT_DIR/stop-comms.sh"
STOPALL
chmod +x "$TEAM_DIR/stop-fagents.sh"

# restart-fagents.sh (atomic restart via launchd — safe for agents to call on themselves)
cat > "$TEAM_DIR/restart-fagents.sh" << 'RESTARTALL'
#!/bin/bash
# Restart everything atomically via launchd.
# Safe for agents to call — launchd drives the stop→start, not the calling process.
set -euo pipefail
if [[ -f /Library/LaunchDaemons/ai.fagents.plist ]]; then
    exec launchctl kickstart -k system/ai.fagents
else
    echo "ERROR: fagents launchd plist not found. Use stop-fagents.sh + start-fagents.sh manually." >&2
    exit 1
fi
RESTARTALL
chmod +x "$TEAM_DIR/restart-fagents.sh"

log_ok "Created $TEAM_DIR/{start,stop,restart}-{fagents,team,comms}.sh"

# Post-install tools
cp "$SCRIPT_DIR/add-email.sh" "$TEAM_DIR/add-email.sh"
chmod +x "$TEAM_DIR/add-email.sh"
cp "$SCRIPT_DIR/install-agent.sh" "$TEAM_DIR/install-agent.sh"
chmod +x "$TEAM_DIR/install-agent.sh"

chown -R "$INFRA_USER:fagent" "$TEAM_DIR"

# ── Launchd plist for boot persistence ──
cat > /Library/LaunchDaemons/ai.fagents.plist << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>ai.fagents</string>
    <key>ProgramArguments</key>
    <array>
        <string>$TEAM_DIR/start-fagents.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$INFRA_HOME/fagents-boot.log</string>
    <key>StandardErrorPath</key>
    <string>$INFRA_HOME/fagents-boot.log</string>
</dict>
</plist>
PLISTEOF
chmod 644 /Library/LaunchDaemons/ai.fagents.plist
log_ok "Launchd plist created — team starts on boot"
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
        echo "     sudo -Hu$user bash -lc 'claude login'"
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
