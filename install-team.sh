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
# Contract vars that can arrive via the install.sh config blob use env-preserving
# defaults (${VAR:-...}) so a blob-exported value is not clobbered here.
COMMS_PORT="${COMMS_PORT:-9754}"
COMMS_REPO="https://github.com/fagents/fagents-comms.git"
SKIP_CLAUDE_AUTH="${SKIP_CLAUDE_AUTH:-}"
SKIP_CODEX_AUTH=""
VERBOSE=""
HUMAN_NAMES=()
INFRA_USER="fagents"
HARDENING_DONE=""
EMAIL_PORT=""
EMAIL_CONFIGURED=""

OPENAI_API_KEY="${OPENAI_API_KEY:-}"
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
        --skip-codex-auth)     SKIP_CODEX_AUTH=1; shift ;;
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

# Resolve an existing user's home dir WITHOUT `eval echo "~$user"` (which
# shell-expands the user name and is dangerous if the name is attacker-
# influenceable). passwd is the canonical home-dir source on Linux.
lookup_home() { getent passwd "$1" | cut -d: -f6; }

# ── Memory check ──
_mem_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
if [[ "$_mem_mb" -gt 0 && "$_mem_mb" -lt 2048 ]]; then
    log_warn "Low memory: ${_mem_mb}MB — Claude Code install may fail (OOM). 2GB+ recommended."
fi

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
# Security hardening (setup-security.sh) was interactive-only and never part of
# the automated path. It is now a manual step: run `sudo bash setup-security.sh`
# after install. HARDENING_DONE stays empty (memory note at end is skipped).

# ── Step 0: Introductions ──
log_step "Step 0: Introductions"
echo ""
echo "Welcome to fagents!"
echo "Your team starts with two agents (ops can add more later):"
echo "  ops  — infrastructure, system admin, sudo, team management"
echo "  comms — Telegram, X, email, voice — your team's interface to the outside world"
echo ""

# Agent names come from env (OPS_AGENT_NAME / COMMS_AGENT_NAME) or their defaults.

# Agent names
OPS_USER="$(echo "$OPS_AGENT_NAME" | tr '[:upper:]' '[:lower:]')"
COMMS_USER="$(echo "$COMMS_AGENT_NAME" | tr '[:upper:]' '[:lower:]')"
AGENT_NAMES=("$OPS_AGENT_NAME" "$COMMS_AGENT_NAME")
AGENT_USERS=("$OPS_USER" "$COMMS_USER")

# Per-agent backend selection + filtering in one pass
declare -A AGENT_BACKENDS
CLAUDE_AGENTS=()
CODEX_AGENTS=()
for user in "${AGENT_USERS[@]}"; do
    backend_key=$(printf '%s' "$user" | tr '[:lower:]-' '[:upper:]_')
    backend_var="AGENT_BACKEND_${backend_key}"
    if [[ -n "${!backend_var:-}" ]]; then
        AGENT_BACKENDS["$user"]="${!backend_var}"
    else
        AGENT_BACKENDS["$user"]="claude"
    fi
    case "${AGENT_BACKENDS[$user]}" in
        claude) CLAUDE_AGENTS+=("$user") ;;
        codex)  CODEX_AGENTS+=("$user") ;;
        *)
            log_err "Invalid backend '${AGENT_BACKENDS[$user]}' for $user (must be claude or codex)"
            exit 1
            ;;
    esac
done

# Comms port comes from env (COMMS_PORT) or its default.

# Human names (space-separated in HUMAN_NAMES_INPUT)
if [[ -n "${HUMAN_NAMES_INPUT:-}" ]]; then
    for human_name in $HUMAN_NAMES_INPUT; do
        HUMAN_NAMES+=("$human_name")
    done
fi
if [[ ${#HUMAN_NAMES[@]} -eq 0 ]]; then
    echo "ERROR: At least one human name is required (HUMAN_NAMES_INPUT)." >&2
    exit 1
fi

# Validate contract values that flow into shell command strings (`su -c`,
# `sudo bash -lc`) and other shell-sensitive sinks. A name or port containing
# a single quote, $, ;, backtick, etc. would otherwise break out of inner
# quoted positions and execute as the infra user. Rejecting early makes every
# downstream interpolation safe by construction (the page's HTML pattern is
# UI-only; the threat model includes tampered blobs and direct env automation).
for _n in "$OPS_AGENT_NAME" "$COMMS_AGENT_NAME"; do
    [[ "$_n" =~ ^[A-Za-z][A-Za-z0-9]*$ ]] || {
        echo "ERROR: Invalid agent name '$_n' (must match [A-Za-z][A-Za-z0-9]*)." >&2
        exit 1
    }
done
for _h in "${HUMAN_NAMES[@]}"; do
    [[ "$_h" =~ ^[A-Za-z][A-Za-z0-9._-]*$ ]] || {
        echo "ERROR: Invalid human name '$_h' (letters/digits/._- only)." >&2
        exit 1
    }
done
[[ "$COMMS_PORT" =~ ^[0-9]+$ ]] || {
    echo "ERROR: Invalid COMMS_PORT '$COMMS_PORT' (must be numeric)." >&2
    exit 1
}

# Claude OAuth token comes from env (CLAUDE_TOKEN); empty = set up manually later.
CLAUDE_TOKEN="${CLAUDE_TOKEN:-}"

# OAuth code+verifier from fagents.ai/install/'s Authorize button: exchange them
# here for the {access,refresh}_token pair Claude Code stores in credentials.json.
# Anthropic returns a misleading "rate_limit_error" without the User-Agent and
# anthropic-beta headers (even on first request); both are required.
#
# Pro/Max subscriptions only grant scope=user:inference -- the access_token works
# directly for /v1/messages, but expires in 8 hours, so we MUST also persist
# refresh_token + expiresAt so the CLI can rotate. Console-account API-key
# mint (org:create_api_key scope) is silently dropped for subscriptions, so we
# don't try.
CLAUDE_OAUTH_HAS_TOKENS=""
if [[ -z "$CLAUDE_TOKEN" && -n "${CLAUDE_OAUTH_CODE:-}" && -n "${CLAUDE_OAUTH_VERIFIER:-}" ]]; then
    # The auth code Anthropic shows is "code#state" formatted; split before sending.
    _oauth_code="${CLAUDE_OAUTH_CODE%%#*}"
    _oauth_state="${CLAUDE_OAUTH_CODE##*#}"
    _oauth_resp=$(curl -sS -X POST "https://platform.claude.com/v1/oauth/token" \
        -H "User-Agent: claude-cli/external-fagents-install" \
        -H "Content-Type: application/json" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -d "$(jq -nc \
            --arg c "$_oauth_code" --arg s "$_oauth_state" --arg v "$CLAUDE_OAUTH_VERIFIER" \
            '{grant_type:"authorization_code",code:$c,state:$s,code_verifier:$v,
              client_id:"9d1c250a-e61b-44d9-88ed-5944d1962f5e",
              redirect_uri:"https://platform.claude.com/oauth/code/callback"}')" 2>/dev/null \
        || echo '')
    CLAUDE_OAUTH_ACCESS_TOKEN=$(printf '%s' "$_oauth_resp" | jq -r '.access_token // empty' 2>/dev/null)
    CLAUDE_OAUTH_REFRESH_TOKEN=$(printf '%s' "$_oauth_resp" | jq -r '.refresh_token // empty' 2>/dev/null)
    CLAUDE_OAUTH_EXPIRES_IN=$(printf '%s' "$_oauth_resp" | jq -r '.expires_in // 28800' 2>/dev/null)
    if [[ -n "$CLAUDE_OAUTH_ACCESS_TOKEN" && -n "$CLAUDE_OAUTH_REFRESH_TOKEN" ]]; then
        CLAUDE_TOKEN="$CLAUDE_OAUTH_ACCESS_TOKEN"   # signals "auth provided" to step 6
        CLAUDE_OAUTH_HAS_TOKENS=1
    else
        echo "WARN: Claude OAuth code exchange failed. Response: $_oauth_resp" >&2
    fi
fi

# OpenAI API key powers Telegram/WhatsApp voice AND Codex api-key auth, so it is
# consumed here independently of any single integration (not gated on Telegram).
[[ -n "${OPENAI_API_KEY_INPUT:-}" ]] && OPENAI_API_KEY="$OPENAI_API_KEY_INPUT"

# ── Email config (Linux only, scoped to comms agent) ──
EMAIL_PORT=$((COMMS_PORT + 1))
declare -A EMAIL_FROM
declare -A EMAIL_SMTP_USER
declare -A EMAIL_SMTP_PASS
declare -A EMAIL_IMAP_USER
declare -A EMAIL_IMAP_PASS
EMAIL_ENABLED=""
# Enabled via EMAIL_ENABLE=1 with EMAIL_*_INPUT fields (see fagents.ai/install/).
# Required fields are validated up-front -- if any are blank, warn and skip so
# a half-completed config does not abort the whole install (install-email.sh
# would `exit 1` on a blank SMTP host/user/pass under `set -e`, killing the
# run after users + comms are already created).
# IMAP host/user/pass default to the SMTP value when their _INPUT is blank.
if [[ -n "${EMAIL_ENABLE:-}" ]]; then
    if [[ -z "${EMAIL_FROM_INPUT:-}" || -z "${EMAIL_SMTP_HOST_INPUT:-}" \
       || -z "${EMAIL_SMTP_USER_INPUT:-}" || -z "${EMAIL_SMTP_PASS_INPUT:-}" ]]; then
        log_warn "EMAIL_ENABLE=1 but required fields incomplete (need EMAIL_FROM_INPUT, EMAIL_SMTP_HOST_INPUT, EMAIL_SMTP_USER_INPUT, EMAIL_SMTP_PASS_INPUT) — skipping email setup"
    else
        smtp_host="$EMAIL_SMTP_HOST_INPUT"
        smtp_port="${EMAIL_SMTP_PORT_INPUT:-587}"
        imap_host="${EMAIL_IMAP_HOST_INPUT:-$smtp_host}"
        imap_port="${EMAIL_IMAP_PORT_INPUT:-993}"
        from_addr="$EMAIL_FROM_INPUT"
        _su="$EMAIL_SMTP_USER_INPUT"
        _sp="$EMAIL_SMTP_PASS_INPUT"
        _iu="${EMAIL_IMAP_USER_INPUT:-$_su}"
        _ip="${EMAIL_IMAP_PASS_INPUT:-$_sp}"
        EMAIL_FROM[$COMMS_AGENT_NAME]="$from_addr"
        EMAIL_SMTP_USER[$COMMS_AGENT_NAME]="$_su"
        EMAIL_SMTP_PASS[$COMMS_AGENT_NAME]="$_sp"
        EMAIL_IMAP_USER[$COMMS_AGENT_NAME]="$_iu"
        EMAIL_IMAP_PASS[$COMMS_AGENT_NAME]="$_ip"
        EMAIL_ENABLED=1
    fi
fi

# ── Telegram config (scoped to comms agent) ──
declare -A TELEGRAM_BOT_TOKEN
declare -A TELEGRAM_ALLOWED
if [[ -n "${TELEGRAM_ENABLE:-}" ]]; then
    TELEGRAM_BOT_TOKEN[$COMMS_AGENT_NAME]="${TELEGRAM_BOT_TOKEN_INPUT:-}"
    TELEGRAM_ALLOWED[$COMMS_AGENT_NAME]="${TELEGRAM_ALLOWED_INPUT:-NONE}"
fi

# ── X (Twitter) config (scoped to comms agent) ──
if [[ -n "${X_ENABLE:-}" ]]; then
    X_BEARER_TOKEN="${X_BEARER_TOKEN_INPUT:-}"
    X_CONSUMER_KEY="${X_CONSUMER_KEY_INPUT:-}"
    X_CONSUMER_SECRET="${X_CONSUMER_SECRET_INPUT:-}"
    X_ACCESS_TOKEN="${X_ACCESS_TOKEN_INPUT:-}"
    X_ACCESS_TOKEN_SECRET="${X_ACCESS_TOKEN_SECRET_INPUT:-}"
fi

# ── WhatsApp config (scoped to comms agent) ──
WHATSAPP_CONFIGURED=""
if [[ -n "${WHATSAPP_ENABLE:-}" ]]; then
    if ! command -v node &>/dev/null; then
        log_warn "Node.js not found — skipping WhatsApp (install Node.js and re-run)"
    else
        # Self-chat session is provisioned post-install (QR scan); JID optional now
        WHATSAPP_SELF_JID="${WHATSAPP_SELF_JID_INPUT:-}"
        WHATSAPP_CONFIGURED=1
    fi
fi

# ── Nostr config (NIP-17 DMs, scoped to comms agent) ──
NOSTR_CONFIGURED=""
NOSTR_NSEC_VAL=""
NOSTR_RELAYS_VAL="wss://relay.damus.io,wss://nos.lol,wss://nostr.wine"
NOSTR_ALLOWED_NPUBS_VAL=""
if [[ -n "${NOSTR_ENABLE:-}" ]]; then
    nostr_node_ok=""
    if ! command -v node &>/dev/null; then
        log_warn "Node.js not found -- skipping Nostr (install Node.js and re-run)"
    else
        # nostr-tools transitive deps (@noble/ciphers, @noble/curves, @noble/hashes)
        # require Node >= 20.19. Older Node ships without the crypto APIs they use.
        _node_v=$(node --version 2>/dev/null | sed 's/^v//')
        _node_maj=$(echo "$_node_v" | cut -d. -f1)
        _node_min=$(echo "$_node_v" | cut -d. -f2)
        if [ "$_node_maj" -gt 20 ] || { [ "$_node_maj" -eq 20 ] && [ "$_node_min" -ge 19 ]; }; then
            nostr_node_ok=1
        else
            log_warn "Node $_node_v too old for Nostr (need >=20.19) -- skipping Nostr"
        fi
    fi
    if [[ -n "$nostr_node_ok" ]]; then
        agent_upper=$(echo "$COMMS_AGENT_NAME" | tr '[:lower:]' '[:upper:]')
        nsec_var="NOSTR_NSEC_INPUT_${agent_upper}"
        NOSTR_NSEC_VAL="${!nsec_var:-}"
        NOSTR_RELAYS_VAL="${NOSTR_RELAYS_INPUT:-$NOSTR_RELAYS_VAL}"
        allowed_var="NOSTR_ALLOWED_NPUBS_INPUT_${agent_upper}"
        NOSTR_ALLOWED_NPUBS_VAL="${!allowed_var:-}"
        NOSTR_CONFIGURED=1
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
[[ -n "$WHATSAPP_CONFIGURED" ]] && echo "  WhatsApp:    enabled ($COMMS_AGENT_NAME)" || echo "  WhatsApp:    disabled"
[[ -n "$NOSTR_CONFIGURED" ]] && echo "  Nostr DMs:   enabled ($COMMS_AGENT_NAME)" || echo "  Nostr DMs:   disabled"
[[ -n "$EMAIL_ENABLED" ]] && echo "  Email:       enabled ($COMMS_AGENT_NAME)" || echo "  Email:       disabled"

echo ""
log_warn " $OPS_AGENT_NAME WILL HAVE SUDO. It can break your system. Mistakes will happen."

echo ""

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
INFRA_HOME=$(lookup_home "$INFRA_USER")

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

# Clone fagents-mcp (bare + working copy, no build — built when email is configured)
MCP_REPO="https://github.com/fagents/fagents-mcp.git"
SHARED_MCP="$INFRA_HOME/repos/fagents-mcp.git"
if [[ -d "$SHARED_MCP" ]]; then
    log_ok "fagents-mcp.git already at $SHARED_MCP"
else
    if su - "$INFRA_USER" -c "git clone --bare '$MCP_REPO' ~/repos/fagents-mcp.git" 2>&1 | log_verbose; then
        su - "$INFRA_USER" -c "git -C ~/repos/fagents-mcp.git remote remove origin" 2>/dev/null || true
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
    if su - "$INFRA_USER" -c "git clone '$SHARED_MCP' ~/workspace/fagents-mcp" 2>&1 | log_verbose; then
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
    if su - "$INFRA_USER" -c "git clone --bare '$FAGENTS_REPO' ~/repos/fagents.git" 2>&1 | log_verbose; then
        su - "$INFRA_USER" -c "git -C ~/repos/fagents.git remote remove origin" 2>/dev/null || true
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
    if su - "$INFRA_USER" -c "git clone '$SHARED_FAGENTS' ~/workspace/fagents" 2>&1 | log_verbose; then
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
    sudo -u "$INFRA_USER" bash -c "cat > '$SHARED_AUTONOMY_WORKING/TEAM.md'" <<< "$TEAM_CONTENT"
    log_ok "TEAM.md generated from base template (untracked)"
fi

# Ensure repos dir is group-writable (install-agent.sh creates per-agent bare repos there)
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
    # printf %q safely quotes the name for the inner shell of `su -c`. Without
    # it, a name containing a single quote would close the surrounding '...'
    # and execute arbitrary commands as the infra user.
    qname=$(printf '%q' "$name")
    output=$(su - "$INFRA_USER" -c "cd ~/workspace/fagents-comms && python3 server.py --data-dir ~/.agents/comms add-agent $qname" 2>&1) || true
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
    # printf %q safely quotes the human name for the inner shell of `su -c`.
    qhuman=$(printf '%q' "$human")
    output=$(su - "$INFRA_USER" -c "cd ~/workspace/fagents-comms && python3 server.py --data-dir ~/.agents/comms add-agent $qhuman" 2>&1) || true
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
    su - "$INFRA_USER" -c "mkdir -p ~/.agents/comms"
    su - "$INFRA_USER" -c "cd ~/workspace/fagents-comms && nohup python3 server.py serve --port $COMMS_PORT --data-dir $INFRA_HOME/.agents/comms </dev/null >comms.log 2>&1 &"
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

    _agent_backend="${AGENT_BACKENDS[$user]:-claude}"
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
        export REPOS_DIR='$REPOS_DIR'
        export DAEMON_BACKEND='$_agent_backend'
        bash '$INSTALL_SCRIPT'
    " 2>&1) || true
    [[ -n "${VERBOSE:-}" ]] && echo "$_out" | sed 's/^/  /'

    agent_home=$(lookup_home "$user")
    agent_ws="$agent_home/workspace/$user"

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

# Set up DEPLOYLOG check cron for ops agent (daily at 9am)
OPS_HOME=$(lookup_home "$OPS_USER")
if [[ -d "$SHARED_AUTONOMY_WORKING" ]] && [[ -d "$OPS_HOME/workspace/$OPS_USER" ]]; then
    su - "$OPS_USER" -c "
        PROJECT_DIR=~/workspace/$OPS_USER \
        bash '$SHARED_AUTONOMY_WORKING/cron.sh' add deploylog-check '0 9 * * *' \
            'Check for new DEPLOYLOGs. Use /fagents-deploylog to check. Never deploy without human ACK.'
    " 2>/dev/null && log_ok "DEPLOYLOG check cron (daily 9am) set for $OPS_AGENT_NAME" || true
fi

# ── Step 5b: Email MCP setup (Linux only, comms agent) ──
if [[ -n "$EMAIL_ENABLED" ]]; then
    log_step "Step 5b: Email setup"

    email_agent_args=(--agent "$COMMS_AGENT_NAME:${AGENT_TOKENS[$COMMS_AGENT_NAME]:-}:${EMAIL_FROM[$COMMS_AGENT_NAME]:-}:${EMAIL_SMTP_USER[$COMMS_AGENT_NAME]:-}:${EMAIL_SMTP_PASS[$COMMS_AGENT_NAME]:-}:${EMAIL_IMAP_USER[$COMMS_AGENT_NAME]:-}:${EMAIL_IMAP_PASS[$COMMS_AGENT_NAME]:-}:$COMMS_USER")

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
    agent_ws="$(lookup_home "$COMMS_USER")/workspace/$COMMS_USER"
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
    # Create #email-log channel for gate_email audit trail
    curl -sf -X POST "http://127.0.0.1:$COMMS_PORT/api/channels/email-log/messages" \
        -H "Authorization: Bearer ${AGENT_TOKENS[$COMMS_AGENT_NAME]:-}" \
        -H "Content-Type: application/json" \
        -d '{"message": "Email audit log initialized."}' > /dev/null 2>&1 || true
    log_ok "#email-log channel created"

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

# Store the OpenAI key in the comms agent's voice credential store ONLY when a
# voice-capable integration is enabled. A Codex-only key (consumed auth-level
# above for `codex login`) must not fan out into openai.env, which only voice
# (Telegram/WhatsApp TTS+STT) reads.
if [[ -n "$OPENAI_API_KEY" && ( -n "${TELEGRAM_ENABLE:-}" || -n "${WHATSAPP_ENABLE:-}" ) ]]; then
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

# ── Step 5e: WhatsApp setup (comms agent) ──
if [[ -n "$WHATSAPP_CONFIGURED" ]]; then
    log_step "Step 5e: WhatsApp setup"

    mkdir -p "$INFRA_HOME/.agents"
    agent_dir="$INFRA_HOME/.agents/$COMMS_USER"
    mkdir -p "$agent_dir"

    cat > "$agent_dir/whatsapp.env" <<WAEOF
WHATSAPP_ALLOWED_JIDS=${WHATSAPP_SELF_JID:-}
WHATSAPP_SELF_JID=${WHATSAPP_SELF_JID:-}
WAEOF

    # Create spool + outbox + session dirs
    mkdir -p "$agent_dir/whatsapp-spool" "$agent_dir/whatsapp-outbox" "$agent_dir/whatsapp-session"

    chown -R "$INFRA_USER:fagent" "$agent_dir"
    chmod 700 "$agent_dir"
    chmod 600 "$agent_dir/whatsapp.env"

    # npm install in fagents-cli (if not already done)
    if [[ -n "$CLI_DIR" ]] && [[ -f "$CLI_DIR/package.json" ]]; then
        if [[ ! -d "$CLI_DIR/node_modules" ]]; then
            log_step "  Installing Node.js dependencies for WhatsApp..."
            (cd "$CLI_DIR" && npm install --production 2>&1) || log_warn "npm install failed — WhatsApp may not work"
        fi
    fi

    # Sudoers — append whatsapp.mjs to existing rule, or create new
    if [[ -n "$CLI_DIR" ]] && [[ -d "$CLI_DIR" ]]; then
        if [[ -f "/etc/sudoers.d/${COMMS_USER}-telegram" ]]; then
            existing=$(cat "/etc/sudoers.d/${COMMS_USER}-telegram")
            echo "${existing}, $CLI_DIR/whatsapp.mjs" > "/etc/sudoers.d/${COMMS_USER}-telegram"
            chmod 440 "/etc/sudoers.d/${COMMS_USER}-telegram"
        else
            echo "$COMMS_USER ALL=($INFRA_USER) NOPASSWD: $CLI_DIR/whatsapp.mjs" > "/etc/sudoers.d/${COMMS_USER}-whatsapp"
            chmod 440 "/etc/sudoers.d/${COMMS_USER}-whatsapp"
        fi
    fi

    echo ""
    echo "  To complete WhatsApp setup, run as $COMMS_USER:"
    echo "    sudo -u $INFRA_USER $CLI_DIR/whatsapp.mjs login"
    echo "  Then scan the QR code with your phone."

    log_ok "$COMMS_AGENT_NAME: WhatsApp configured"
fi

# ── Step 5f: Nostr DM setup (comms agent) ──
if [[ -n "$NOSTR_CONFIGURED" ]]; then
    log_step "Step 5f: Nostr DM setup"

    mkdir -p "$INFRA_HOME/.agents"
    agent_dir="$INFRA_HOME/.agents/$COMMS_USER"
    mkdir -p "$agent_dir"

    # CRITICAL: chown the agent dir + create the seed env AS $INFRA_USER BEFORE
    # running `nostr.mjs login`. Otherwise the file is root:600 and the sudo
    # login command can't read or rewrite it -- login silently fails and the
    # generated NSEC/NPUB never land in the env file.
    chown "$INFRA_USER:fagent" "$agent_dir"
    chmod 700 "$agent_dir"
    sudo -u "$INFRA_USER" tee "$agent_dir/nostr.env" >/dev/null <<NOSTREOF
NOSTR_RELAYS=$NOSTR_RELAYS_VAL
NOSTR_ALLOWED_NPUBS=$NOSTR_ALLOWED_NPUBS_VAL
NOSTREOF
    chmod 600 "$agent_dir/nostr.env"

    nostr_setup_failed=""

    # Pre-flight: require both fagents-cli/package.json and fagents-cli/nostr.mjs.
    # An older or partially-cloned fagents-cli checkout has package.json but no
    # nostr.mjs; the previous logic silently skipped the login step and reached
    # the success log. Require both up front.
    if [[ -z "$CLI_DIR" ]] || [[ ! -f "$CLI_DIR/package.json" ]] || [[ ! -f "$CLI_DIR/nostr.mjs" ]]; then
        log_warn "fagents-cli is missing or stale at $CLI_DIR (no nostr.mjs / package.json) -- Nostr setup aborted"
        nostr_setup_failed=1
    fi

    # npm install: check for the SPECIFIC Nostr packages, not just node_modules/.
    # An existing WhatsApp install populates node_modules/ but doesn't include
    # nostr-tools or our pinned ws. Skipping npm in that case would land us at
    # `nostr.mjs login` -> module-not-found -> false success.
    if [[ -z "$nostr_setup_failed" ]]; then
        if [[ ! -f "$CLI_DIR/node_modules/nostr-tools/package.json" ]] || \
           [[ ! -f "$CLI_DIR/node_modules/ws/package.json" ]]; then
            log_step "  Installing Node.js dependencies for Nostr..."
            if ! (cd "$CLI_DIR" && npm install --production 2>&1); then
                log_warn "npm install failed -- Nostr setup aborted"
                nostr_setup_failed=1
            fi
        fi
        # Verify packages are actually present after the install attempt.
        # Defends against npm exit=0 + partial install or a stale package.json
        # that doesn't declare nostr-tools at all.
        if [[ -z "$nostr_setup_failed" ]]; then
            if [[ ! -f "$CLI_DIR/node_modules/nostr-tools/package.json" ]] || \
               [[ ! -f "$CLI_DIR/node_modules/ws/package.json" ]]; then
                log_warn "Nostr deps missing after npm install (check $CLI_DIR/package.json declares nostr-tools+ws) -- aborting"
                nostr_setup_failed=1
            fi
        fi
    fi

    # Generate or import nsec via nostr.mjs login (MERGES into env file).
    # Env file is now $INFRA_USER-owned (above), so this can read+rewrite it.
    if [[ -z "$nostr_setup_failed" ]]; then
        login_args=()
        [[ -n "$NOSTR_NSEC_VAL" ]] && login_args=(--nsec "$NOSTR_NSEC_VAL")
        if ! login_out=$(sudo -u "$INFRA_USER" "$CLI_DIR/nostr.mjs" --env-file "$agent_dir/nostr.env" login "${login_args[@]}" 2>/dev/null); then
            log_warn "Nostr login failed -- run manually: sudo -u $INFRA_USER $CLI_DIR/nostr.mjs --env-file $agent_dir/nostr.env login"
            nostr_setup_failed=1
        else
            npub_display=$(echo "$login_out" | python3 -c "import sys,json; print(json.load(sys.stdin).get('npub',''))" 2>/dev/null) || npub_display=""
            # Verify login actually wrote NSEC/NPUB into the env file.
            if ! grep -q '^NOSTR_NSEC=' "$agent_dir/nostr.env" 2>/dev/null; then
                log_warn "nostr.env is missing NOSTR_NSEC after login -- check $agent_dir/nostr.env perms"
                nostr_setup_failed=1
            fi
        fi
    fi

    mkdir -p "$agent_dir/nostr-spool" "$agent_dir/nostr-outbox"
    chown -R "$INFRA_USER:fagent" "$agent_dir"
    # 750 (not 700) so the agent's daemon user can traverse this dir to check
    # `[ -f "$NOSTR_ENV_FILE" ]` in ensure_nostr_serve / collect_nostr. The
    # individual 0600 files remain unreadable to non-fagents users -- only
    # the filenames are visible to fagent-group members. Same group ownership
    # the rest of the install assumes.
    chmod 750 "$agent_dir"
    chmod 600 "$agent_dir/nostr.env"

    # Sudoers -- append nostr.mjs to existing rule, or create new
    if [[ -n "$CLI_DIR" ]] && [[ -d "$CLI_DIR" ]]; then
        if [[ -f "/etc/sudoers.d/${COMMS_USER}-telegram" ]]; then
            existing=$(cat "/etc/sudoers.d/${COMMS_USER}-telegram")
            echo "${existing}, $CLI_DIR/nostr.mjs" > "/etc/sudoers.d/${COMMS_USER}-telegram"
            chmod 440 "/etc/sudoers.d/${COMMS_USER}-telegram"
        else
            echo "$COMMS_USER ALL=($INFRA_USER) NOPASSWD: $CLI_DIR/nostr.mjs" > "/etc/sudoers.d/${COMMS_USER}-nostr"
            chmod 440 "/etc/sudoers.d/${COMMS_USER}-nostr"
        fi
    fi

    if [[ -z "$nostr_setup_failed" ]] && [[ -n "${npub_display:-}" ]]; then
        echo ""
        echo "  Your agent's Nostr npub (share this with humans / other agents):"
        echo "    $npub_display"
    fi
    if [[ -z "$nostr_setup_failed" ]]; then
        echo ""
        echo "  Re-display anytime: sudo -u $INFRA_USER $CLI_DIR/nostr.mjs --env-file $agent_dir/nostr.env whoami"
    fi

    if [[ -n "$nostr_setup_failed" ]]; then
        # Clear the flag so the summary line knows Nostr isn't configured.
        NOSTR_CONFIGURED=""
        # Remove the partial nostr.env: it has relays + maybe an allow-list but
        # no NOSTR_NSEC. Daemon's grep-for-NSEC guard would skip it anyway, but
        # a missing file is cleaner than a half-written one. Operator re-runs
        # setup to recreate.
        if [[ -n "${agent_dir:-}" ]] && [[ -f "$agent_dir/nostr.env" ]]; then
            rm -f "$agent_dir/nostr.env"
        fi
        log_warn "$COMMS_AGENT_NAME: Nostr DMs setup INCOMPLETE -- daemon will skip Nostr until you re-run setup"
    else
        log_ok "$COMMS_AGENT_NAME: Nostr DMs configured"
    fi
fi

# ── Step 6: Backend CLI setup ──
log_step "Step 6: Backend CLI setup"

# Claude agents
if [[ ${#CLAUDE_AGENTS[@]} -gt 0 && -z "$SKIP_CLAUDE_AUTH" ]]; then
    echo "  Claude agents: ${CLAUDE_AGENTS[*]}"
    for user in "${CLAUDE_AGENTS[@]}"; do
        if su - "$user" -c "command -v claude" &>/dev/null; then
            log_ok "$user: Claude Code already installed"
        else
            echo "  $user: Installing Claude Code..."
            run su - "$user" -c "curl -fsSL https://claude.ai/install.sh | bash"
            if su - "$user" -c "command -v claude" &>/dev/null; then
                log_ok "$user: Claude Code installed"
            else
                log_warn "Claude Code installation failed for $user"
            fi
        fi
    done

    if [[ -n "$CLAUDE_TOKEN" ]]; then
        for user in "${CLAUDE_AGENTS[@]}"; do
            agent_home=$(lookup_home "$user")
            agent_ws="$agent_home/workspace/$user"
            su - "$user" -c "mkdir -p ~/.claude && echo '{\"hasCompletedOnboarding\": true}' > ~/.claude.json"
            if [[ -n "$CLAUDE_OAUTH_HAS_TOKENS" ]]; then
                # Refresh-token flow (Pro/Max subscribers): write the JSON shape
                # the CLI's credentials.json reader expects. Don't put the token
                # in .env -- CLAUDE_CODE_OAUTH_TOKEN would override the file at
                # runtime and freeze us at the 8-hour expiry.
                _expires_at_ms=$(( ($(date +%s) + CLAUDE_OAUTH_EXPIRES_IN) * 1000 ))
                _cred_json=$(jq -nc \
                    --arg at "$CLAUDE_OAUTH_ACCESS_TOKEN" \
                    --arg rt "$CLAUDE_OAUTH_REFRESH_TOKEN" \
                    --argjson ex "$_expires_at_ms" \
                    '{claudeAiOauth:{accessToken:$at,refreshToken:$rt,expiresAt:$ex,
                                     scopes:["user:inference"],subscriptionType:null,
                                     rateLimitTier:null,
                                     clientId:"9d1c250a-e61b-44d9-88ed-5944d1962f5e"}}')
                su - "$user" -c "printf '%s' $(printf '%q' "$_cred_json") > ~/.claude/.credentials.json && chmod 600 ~/.claude/.credentials.json"
                log_ok "$user: Claude OAuth credentials.json written (access+refresh)"
            else
                # Legacy long-lived API key (Console/manual paste): env var path.
                if ! grep -q "CLAUDE_CODE_OAUTH_TOKEN" "$agent_ws/.env" 2>/dev/null; then
                    echo "export CLAUDE_CODE_OAUTH_TOKEN=\"$CLAUDE_TOKEN\"" >> "$agent_ws/.env"
                fi
                chown "$user:fagent" "$agent_ws/.env"
                chmod 600 "$agent_ws/.env"
                log_ok "$user: Claude auth configured"
            fi
        done
    else
        echo "  Claude auth skipped — set up manually later."
    fi
fi

# Codex agents
if [[ ${#CODEX_AGENTS[@]} -gt 0 ]]; then
    # Derive auth mode: explicit CODEX_AUTH_MODE > skip flag > OPENAI_API_KEY heuristic.
    if [[ -n "$SKIP_CODEX_AUTH" ]]; then
        CODEX_AUTH_MODE="skip"
    elif [[ -z "${CODEX_AUTH_MODE:-}" ]]; then
        # Installer is non-interactive: derive from OPENAI_API_KEY, else require an
        # explicit mode (oauth needs a TTY, so it must be opted into deliberately).
        if [[ -n "${OPENAI_API_KEY:-}" ]]; then
            CODEX_AUTH_MODE="api-key-login"
        else
            log_err "Codex install requires OPENAI_API_KEY, or set CODEX_AUTH_MODE (oauth|api-key-login|api-key-env|skip)"
            exit 1
        fi
    fi
    echo "  Codex agents: ${CODEX_AGENTS[*]}"

    # Prerequisite: Node.js + npm
    if ! command -v node &>/dev/null || ! command -v npm &>/dev/null; then
        echo "  Installing Node.js (required for Codex CLI)..."
        run apt-get update -qq
        run apt-get install -y nodejs npm
        if command -v node &>/dev/null && command -v npm &>/dev/null; then
            log_ok "Node.js + npm installed"
        else
            log_err "Node.js install failed — run: apt-get install -y nodejs npm"
            exit 1
        fi
    fi

    # Install Codex CLI globally
    if ! command -v codex &>/dev/null; then
        echo "  Installing Codex CLI..."
        run npm install -g @openai/codex
        if ! command -v codex &>/dev/null; then
            log_err "Codex CLI install failed — run: npm install -g @openai/codex"
            exit 1
        fi
    fi
    log_ok "Codex CLI installed"

    # Verify first Codex agent can reach codex (global install, same PATH for all)
    _first_codex="${CODEX_AGENTS[0]}"
    if su - "$_first_codex" -c "command -v codex && codex --version" &>/dev/null; then
        log_ok "Codex CLI reachable (verified as $_first_codex)"
    else
        log_err "codex not in PATH for $_first_codex — check npm global prefix"
        exit 1
    fi

    # Auth
    CODEX_AUTH_MODE="${CODEX_AUTH_MODE:-oauth}"
    for user in "${CODEX_AGENTS[@]}"; do
        agent_home=$(lookup_home "$user")
        agent_ws="$agent_home/workspace/$user"
        codex_home="$agent_home/.codex"

        # codex CLI errors out with "CODEX_HOME points to ... but that path
        # does not exist" if the dir is missing -- create as the agent user
        # so ownership/permissions are right.
        su - "$user" -c "mkdir -p '$codex_home' && chmod 700 '$codex_home'"

        case "$CODEX_AUTH_MODE" in
            oauth)
                echo "  $user: Codex login (device auth)..."
                su - "$user" -c "CODEX_HOME='$codex_home' codex login --device-auth" || {
                    log_warn "$user: codex login failed — set up manually later"
                    continue
                }
                _status=$(su - "$user" -c "CODEX_HOME='$codex_home' codex login status" 2>&1) || true
                if echo "$_status" | grep -q "^Logged in"; then
                    log_ok "$user: Codex auth configured (OAuth)"
                else
                    log_warn "$user: codex login status unclear — verify manually"
                fi
                ;;
            api-key-login)
                if [[ -z "${OPENAI_API_KEY:-}" ]]; then
                    log_err "OPENAI_API_KEY required for api-key-login mode"
                    exit 1
                fi
                echo "$OPENAI_API_KEY" | su - "$user" -c "CODEX_HOME='$codex_home' codex login --with-api-key"
                _status=$(su - "$user" -c "CODEX_HOME='$codex_home' codex login status" 2>&1) || true
                if echo "$_status" | grep -q "^Logged in"; then
                    log_ok "$user: Codex auth configured (API key login)"
                else
                    log_warn "$user: codex login status unclear — verify manually"
                fi
                ;;
            api-key-env)
                if [[ -z "${OPENAI_API_KEY:-}" ]]; then
                    log_err "OPENAI_API_KEY required for api-key-env mode"
                    exit 1
                fi
                if ! grep -q "OPENAI_API_KEY" "$agent_ws/.env" 2>/dev/null; then
                    echo "export OPENAI_API_KEY=\"$OPENAI_API_KEY\"" >> "$agent_ws/.env"
                fi
                chown "$user:fagent" "$agent_ws/.env"
                chmod 600 "$agent_ws/.env"
                log_ok "$user: Codex auth configured (env key)"
                ;;
            skip)
                echo "  $user: Codex auth skipped"
                ;;
            *)
                log_err "Invalid CODEX_AUTH_MODE='$CODEX_AUTH_MODE' (must be oauth|api-key-login|api-key-env|skip)"
                exit 1
                ;;
        esac
    done
fi

if [[ ${#CLAUDE_AGENTS[@]} -eq 0 && ${#CODEX_AGENTS[@]} -eq 0 ]]; then
    echo "  No agents to configure (all auth skipped)."
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
    su - "$INFRA_USER" -c "mkdir -p ~/.agents/comms && cd ~/workspace/fagents-comms && nohup python3 server.py serve --port $COMMS_PORT --data-dir $INFRA_HOME/.agents/comms </dev/null >comms.log 2>&1 &"
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
    user_home=$(lookup_home "$user")
    cat >> "$TEAM_DIR/stop-team.sh" << AGENTSTOP
mkdir -p "$user_home/workspace/$user/.autonomy"
touch "$user_home/workspace/$user/.autonomy/daemon.stopped"
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

# restart-fagents.sh (atomic restart via systemd — safe for agents to call on themselves)
cat > "$TEAM_DIR/restart-fagents.sh" << 'RESTARTALL'
#!/bin/bash
# Restart everything atomically via systemd.
# Safe for agents to call — systemd drives the stop→start, not the calling process.
set -euo pipefail
if command -v systemctl &>/dev/null && systemctl is-enabled --quiet fagents 2>/dev/null; then
    exec systemctl restart fagents
else
    echo "ERROR: fagents systemd service not found. Use stop-fagents.sh + start-fagents.sh manually." >&2
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

# Health check cron — fagents user checks daemon liveness every hour
HEALTH_CHECK="$SHARED_AUTONOMY_WORKING/health-check.sh"
if [[ -f "$HEALTH_CHECK" ]]; then
    _cron_line="0 * * * * bash $HEALTH_CHECK"
    _existing=$(su - "$INFRA_USER" -c "crontab -l" 2>/dev/null || true)
    _new=$(echo "$_existing" | grep -v 'health-check.sh'; echo "$_cron_line")
    if echo "$_new" | su - "$INFRA_USER" -c "crontab -" 2>/dev/null; then
        log_ok "Health check cron (hourly) set for $INFRA_USER"
    else
        log_warn "Failed to set health check cron for $INFRA_USER"
    fi
fi

# ── Systemd service for boot persistence ──
cat > /etc/systemd/system/fagents.service << SVCEOF
[Unit]
Description=fagents — autonomous agent team
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$TEAM_DIR/start-fagents.sh
ExecStop=$TEAM_DIR/stop-fagents.sh

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl enable fagents --quiet 2>/dev/null
log_ok "Systemd service created — team starts on boot"
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
