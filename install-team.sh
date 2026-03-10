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
SKIP_CLAUDE_AUTH=""
VERBOSE=""
TEMPLATE=""
AGENTS=()
HUMAN_NAMES=()
INFRA_USER="fagents"
HARDENING_DONE=""
EMAIL_PORT=""
EMAIL_CONFIGURED=""
EMAIL_AGENTS=()
declare -A EMAIL_FROM
declare -A EMAIL_SMTP_USER
declare -A EMAIL_SMTP_PASS
declare -A EMAIL_IMAP_USER
declare -A EMAIL_IMAP_PASS

TELEGRAM_CONFIGURED=""
TELEGRAM_AGENTS=()
declare -A TELEGRAM_BOT_TOKEN
declare -A TELEGRAM_ALLOWED
OPENAI_API_KEY=""

X_CONFIGURED=""
X_AGENTS=()
X_BEARER_TOKEN=""
X_CONSUMER_KEY=""
X_CONSUMER_SECRET=""
X_ACCESS_TOKEN=""
X_ACCESS_TOKEN_SECRET=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTONOMY_REPO="https://github.com/fagents/fagents-autonomy.git"
CLI_REPO="https://github.com/fagents/fagents-cli.git"
CLI_DIR=""

# ── Parse args ──
while [[ $# -gt 0 ]]; do
    case "$1" in
        --template)     TEMPLATE="$2"; shift 2 ;;
        --comms-port)   COMMS_PORT="$2"; shift 2 ;;
        --comms-repo)   COMMS_REPO="$2"; shift 2 ;;
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

# ── Prerequisites ──
_missing_prereqs=()
for cmd in git curl python3 jq; do
    command -v "$cmd" &>/dev/null || _missing_prereqs+=("$cmd")
done
if [[ ${#_missing_prereqs[@]} -gt 0 ]]; then
    echo ""
    echo "Installing prerequisites: ${_missing_prereqs[*]}"
    apt-get update -qq 2>&1 | log_verbose
    apt-get install -y "${_missing_prereqs[@]}" 2>&1 | log_verbose
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
        # Merge into existing .mcp.json
        local tmp
        tmp=$(jq --arg name "$name" --arg url "$url" --arg key "$api_key" \
            '.mcpServers[$name] = {"type": "http", "url": $url, "headers": {"x-api-key": $key}}' \
            "$mcp_file")
        echo "$tmp" > "$mcp_file"
    else
        # Create new .mcp.json
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

# DM channel naming: whimsical for family, plain for business
dm_channel_name() {
    local lname="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
    case "${TEMPLATE:-}" in
        family) echo "${lname}s-cove" ;;
        *)      echo "$lname" ;;
    esac
}

# ── Interactive mode ──
prompt() {
    local var="$1" prompt_text="$2" default="$3"
    # Non-interactive: if var already set in env, keep it
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
    prompt TEMPLATE "Choose a template (or 'none' for manual)" "freeturtle"
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
if [[ -n "${NONINTERACTIVE:-}" && -n "${HUMAN_NAMES_INPUT:-}" ]]; then
    # Non-interactive: parse human names from env var
    for human_name in $HUMAN_NAMES_INPUT; do
        HUMAN_NAMES+=("$human_name")
        HUMAN_ROLES+=("")
        HUMAN_CHANNELS+=("")
        HUMAN_PAIRED_AGENTS+=("")
    done
elif [[ ${#TEMPLATE_HUMANS[@]} -gt 0 ]]; then
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
CLAUDE_TOKEN="${CLAUDE_TOKEN:-}"
if [[ -z "$SKIP_CLAUDE_AUTH" && -z "${NONINTERACTIVE:-}" ]]; then
    echo ""
    echo "All agents need a Claude Code OAuth token to run."
    echo "If Claude Code is not installed yet, run this first:"
    echo "  curl -fsSL https://claude.ai/install.sh | bash && export PATH=\"\$HOME/.local/bin:\$PATH\" && claude setup-token"
    echo "Then paste the token here."
    read -rp "Claude OAuth token (or Enter to skip): " CLAUDE_TOKEN
fi

# ── Email config (collected upfront, installed in Step 5b) ──
EMAIL_PORT=$((COMMS_PORT + 1))
enable_email=""
if [[ -z "${NONINTERACTIVE:-}" ]]; then
    echo ""
    read -rp "Enable email for agents? [y/N]: " enable_email
fi
if [[ "${enable_email,,}" =~ ^y ]]; then
    echo ""
    echo "  Which agents should have email?"
    for i in "${!AGENTS[@]}"; do
        echo "    $((i+1)). ${AGENTS[$i]}"
    done
    echo "    a. All agents"
    echo ""
    read -rp "  Select (numbers separated by spaces, or 'a' for all): " email_selection

    if [[ "$email_selection" == "a" ]]; then
        EMAIL_AGENTS=("${AGENTS[@]}")
    else
        for num in $email_selection; do
            idx=$((num - 1))
            if [[ $idx -ge 0 && $idx -lt ${#AGENTS[@]} ]]; then
                EMAIL_AGENTS+=("${AGENTS[$idx]}")
            fi
        done
    fi

    if [[ ${#EMAIL_AGENTS[@]} -gt 0 ]]; then
        echo ""
        echo "  Mail server (shared — same host for all agents):"
        prompt smtp_host "    SMTP host" ""
        prompt smtp_port "    SMTP port" "587"
        prompt imap_host "    IMAP host" "$smtp_host"
        prompt imap_port "    IMAP port" "993"

        echo ""
        echo "  Per-agent credentials (each agent gets their own account):"
        echo "  Note: passwords cannot contain ':'."
        for name in "${EMAIL_AGENTS[@]}"; do
            echo ""
            echo "    $name:"
            read -rp "      Sends as (from address): " from_addr
            prompt _su "      SMTP user" ""
            read -rsp "      SMTP password: " _sp; echo ""
            prompt _iu "      IMAP user" "$_su"
            read -rsp "      IMAP password (Enter = same as SMTP): " _ip; echo ""
            [[ -z "$_ip" ]] && _ip="$_sp"
            EMAIL_FROM[$name]="$from_addr"
            EMAIL_SMTP_USER[$name]="$_su"
            EMAIL_SMTP_PASS[$name]="$_sp"
            EMAIL_IMAP_USER[$name]="$_iu"
            EMAIL_IMAP_PASS[$name]="$_ip"
        done
    fi
fi

# ── Telegram config (collected upfront, installed in Step 5c) ──
enable_telegram=""
if [[ -z "${NONINTERACTIVE:-}" ]]; then
    echo ""
    read -rp "Enable Telegram for agents? [y/N]: " enable_telegram
elif [[ -n "${TELEGRAM_ENABLE:-}" ]]; then
    enable_telegram="y"
fi
if [[ "${enable_telegram,,}" =~ ^y ]]; then
    if [[ -n "${NONINTERACTIVE:-}" && -n "${TELEGRAM_AGENTS_INPUT:-}" ]]; then
        for name in $TELEGRAM_AGENTS_INPUT; do
            # Match case-insensitively against AGENTS
            for a in "${AGENTS[@]}"; do
                if [[ "${a,,}" == "${name,,}" ]]; then
                    TELEGRAM_AGENTS+=("$a")
                    break
                fi
            done
        done
    elif [[ -z "${NONINTERACTIVE:-}" ]]; then
        echo ""
        echo "  Which agents should have Telegram?"
        for i in "${!AGENTS[@]}"; do
            echo "    $((i+1)). ${AGENTS[$i]}"
        done
        echo "    a. All agents"
        echo ""
        read -rp "  Select (numbers separated by spaces, or 'a' for all): " tg_selection

        if [[ "$tg_selection" == "a" ]]; then
            TELEGRAM_AGENTS=("${AGENTS[@]}")
        else
            for num in $tg_selection; do
                idx=$((num - 1))
                if [[ $idx -ge 0 && $idx -lt ${#AGENTS[@]} ]]; then
                    TELEGRAM_AGENTS+=("${AGENTS[$idx]}")
                fi
            done
        fi
    fi

    if [[ ${#TELEGRAM_AGENTS[@]} -gt 0 ]]; then
        echo ""
        echo "  Per-agent bot tokens (from BotFather — one bot per agent):"
        for name in "${TELEGRAM_AGENTS[@]}"; do
            # Check for NONINTERACTIVE env var first
            local_var="TELEGRAM_BOT_TOKEN_${name^^}"
            if [[ -n "${!local_var:-}" ]]; then
                TELEGRAM_BOT_TOKEN[$name]="${!local_var}"
            elif [[ -z "${NONINTERACTIVE:-}" ]]; then
                read -rsp "    $name bot token: " _tg_token; echo ""
                TELEGRAM_BOT_TOKEN[$name]="$_tg_token"
            fi
        done

        # Discover allowed Telegram user IDs
        if [[ -z "${NONINTERACTIVE:-}" ]]; then
            echo ""
            echo "  Bots are public — anyone can message them."
            echo "  Let's lock each bot to your Telegram account."
            echo ""
            for name in "${TELEGRAM_AGENTS[@]}"; do
                _tk="${TELEGRAM_BOT_TOKEN[$name]:-}"
                [[ -n "$_tk" ]] || continue
                echo "  $name: send /start to the bot now, then press Enter."
                read -rp "    Press Enter when done... "
                # Poll for the user ID
                _resp=$(curl -sf --max-time 10 "https://api.telegram.org/bot${_tk}/getUpdates?timeout=0" 2>/dev/null) || true
                _uid=$(echo "$_resp" | jq -r '[.result[].message.from.id // empty] | unique | first // empty' 2>/dev/null)
                if [[ -n "$_uid" ]]; then
                    TELEGRAM_ALLOWED[$name]="$_uid"
                    _uname=$(echo "$_resp" | jq -r '[.result[].message.from.username // empty] | first // empty' 2>/dev/null)
                    log_ok "$name: locked to user ${_uname:-$_uid} (ID: $_uid)"
                else
                    TELEGRAM_ALLOWED[$name]="NONE"
                    log_warn "$name: no messages found — bot locked (no one can message)"
                    log_warn "  Add your Telegram user ID later in $INFRA_HOME/.agents/$(agent_user "$name")/telegram.env"
                fi
            done
        else
            # NONINTERACTIVE: check for TELEGRAM_ALLOWED_<NAME> env vars, default to locked
            for name in "${TELEGRAM_AGENTS[@]}"; do
                local_var="TELEGRAM_ALLOWED_${name^^}"
                if [[ -n "${!local_var:-}" ]]; then
                    TELEGRAM_ALLOWED[$name]="${!local_var}"
                else
                    TELEGRAM_ALLOWED[$name]="NONE"
                fi
            done
        fi

        # Optional: OpenAI API key for voice (TTS + Whisper STT)
        if [[ -z "${NONINTERACTIVE:-}" ]]; then
            echo ""
            echo "  Optional: OpenAI API key for voice messages (TTS + Whisper STT)."
            read -rsp "    OpenAI API key (blank to skip): " _openai_key; echo ""
            [[ -n "$_openai_key" ]] && OPENAI_API_KEY="$_openai_key"
        else
            OPENAI_API_KEY="${OPENAI_API_KEY_INPUT:-}"
        fi
    fi
fi

# ── X (Twitter) config (collected upfront, installed in Step 5d) ──
enable_x=""
if [[ -z "${NONINTERACTIVE:-}" ]]; then
    echo ""
    read -rp "Enable X (Twitter) for agents? [y/N]: " enable_x
elif [[ -n "${X_ENABLE:-}" ]]; then
    enable_x="y"
fi
if [[ "${enable_x,,}" =~ ^y ]]; then
    if [[ -n "${NONINTERACTIVE:-}" && -n "${X_AGENTS_INPUT:-}" ]]; then
        for name in $X_AGENTS_INPUT; do
            for a in "${AGENTS[@]}"; do
                if [[ "${a,,}" == "${name,,}" ]]; then
                    X_AGENTS+=("$a")
                    break
                fi
            done
        done
    elif [[ -z "${NONINTERACTIVE:-}" ]]; then
        echo ""
        echo "  Which agents should have X (Twitter)?"
        for i in "${!AGENTS[@]}"; do
            echo "    $((i+1)). ${AGENTS[$i]}"
        done
        echo "    a. All agents"
        echo ""
        read -rp "  Select (numbers separated by spaces, or 'a' for all): " x_selection

        if [[ "$x_selection" == "a" ]]; then
            X_AGENTS=("${AGENTS[@]}")
        else
            for num in $x_selection; do
                idx=$((num - 1))
                if [[ $idx -ge 0 && $idx -lt ${#AGENTS[@]} ]]; then
                    X_AGENTS+=("${AGENTS[$idx]}")
                fi
            done
        fi
    fi

    if [[ ${#X_AGENTS[@]} -gt 0 ]]; then
        echo ""
        echo "  X API credentials (shared across all selected agents):"
        echo "  Get these from developer.x.com — one app, all agents share it."
        if [[ -z "${NONINTERACTIVE:-}" ]]; then
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
fi

echo ""
echo "  Infra user:  $INFRA_USER (owns comms + git repos)"
echo "  Agents:      ${AGENTS[*]}"
echo "  Humans:      ${HUMAN_NAMES[*]}"
echo "  Comms:       127.0.0.1:$COMMS_PORT"
[[ -n "$CLAUDE_TOKEN" ]] && echo "  Claude auth: provided" || echo "  Claude auth: skip (set up manually later)"
if [[ ${#EMAIL_AGENTS[@]} -gt 0 ]]; then
    echo "  Email:       enabled (${EMAIL_AGENTS[*]})"
    echo "  SMTP:        ${smtp_host:-}:${smtp_port:-587}"
else
    echo "  Email:       disabled"
fi
if [[ ${#TELEGRAM_AGENTS[@]} -gt 0 ]]; then
    echo "  Telegram:    enabled (${TELEGRAM_AGENTS[*]})"
else
    echo "  Telegram:    disabled"
fi
if [[ ${#X_AGENTS[@]} -gt 0 ]]; then
    echo "  X (Twitter): enabled (${X_AGENTS[*]})"
else
    echo "  X (Twitter): disabled"
fi

# Warn about sudo agents
for name in "${AGENTS[@]}"; do
    if [[ -n "${AGENT_BOOTSTRAP[$name]:-}" ]]; then
        echo ""
        log_warn " $name WILL HAVE SUDO. It can break your system. Mistakes will happen."
    fi
done

echo ""
if [[ -z "${NONINTERACTIVE:-}" ]]; then
    read -rp "Proceed? [Y/n] " confirm
    if [[ "${confirm,,}" == "n" ]]; then
        echo "Aborted."
        exit 0
    fi
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

# Check if a username belongs to a pre-existing non-fagent user
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

# Pre-flight: check all names for conflicts before creating anything
check_user_conflict "$INFRA_USER" "$INFRA_USER"
for name in "${AGENT_NAMES[@]}"; do
    check_user_conflict "$(agent_user "$name")" "$name"
done

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
# Make readable so agents can clone from it
[[ -d "$SHARED_AUTONOMY" ]] && chmod -R g+rX "$SHARED_AUTONOMY"
# Agents clone from local shared copy (fall back to GitHub if clone failed)
[[ -d "$SHARED_AUTONOMY" ]] && AUTONOMY_REPO="$SHARED_AUTONOMY"

# Stage B: Create shared autonomy working clone from bare
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

# Clone fagents-cli (needed for Telegram, useful for all agents)
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

# Stage C: Generate TEAM.md from base template (untracked — gitignored in fagents-autonomy)
BASE_TEAM_TEMPLATE="$SCRIPT_DIR/templates/base/TEAM.md"
if [[ -d "$SHARED_AUTONOMY_WORKING" ]] && [[ -f "$BASE_TEAM_TEMPLATE" ]]; then
    ROLES_BLOCK=""
    for name in "${AGENT_NAMES[@]}"; do
        role="${AGENT_ROLES[$name]:-agent}"
        ROLES_BLOCK+="- **$name** ($role)"$'\n'
    done
    # Merge base template with roles (no git tracking — TEAM.md is gitignored)
    _team_template=$(cat "$BASE_TEAM_TEMPLATE")
    TEAM_CONTENT="${_team_template/<!-- TEAM_ROLES -->/$ROLES_BLOCK}"
    sudo -u "$INFRA_USER" bash -c "cat > '$SHARED_AUTONOMY_WORKING/TEAM.md'" <<< "$TEAM_CONTENT"
    log_ok "TEAM.md generated from base template (untracked)"
fi

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
    [[ -f "$repo/HEAD" ]] && git -C "$repo" config core.sharedRepository group 2>/dev/null || true
done

# Allow all users to work with repos owned by other users in the group
if ! git config --system safe.directory '*' >/dev/null 2>&1; then
    # Fallback: write directly if git config --system fails
    mkdir -p /etc
    printf '[safe]\n\tdirectory = *\n' >> /etc/gitconfig
fi
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
    dm="$(dm_channel_name "$name")"
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
        dm="$(dm_channel_name "$paired")"
        CHANNEL_ALLOW[$dm]+="$human "
    else
        # No explicit pairing — add human to ALL agent coves
        for _agent in "${AGENT_NAMES[@]}"; do
            dm="$(dm_channel_name "$_agent")"
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
    dm="$(dm_channel_name "$name")"
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
            dm="$(dm_channel_name "$paired")"
            channels=$(echo "$tc" | jq -c ". + [\"$dm\"] | unique")
        else
            channels="$tc"
        fi
    else
        # Fallback: general + all agent DMs (non-template flow)
        channels='["general"'
        for name in "${AGENT_NAMES[@]}"; do
            channels+=",\"$(dm_channel_name "$name")\""
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

    su - "$user" -c "
        export NONINTERACTIVE=1
        export AGENT_NAME='$name'
        export WORKSPACE='$ws'
        export GIT_HOST='local'
        export COMMS_URL='http://127.0.0.1:$COMMS_PORT'
        export COMMS_TOKEN='$token'
        export AUTONOMY_REPO='$AUTONOMY_REPO'
        export AUTONOMY_DIR='$SHARED_AUTONOMY_WORKING'
        export AUTONOMY_SHARED=1
        bash '$INSTALL_SCRIPT'
    " 2>&1 | log_verbose

    # Set up git remote pointing to local bare repo
    agent_home=$(eval echo "~$user")
    agent_ws="$agent_home/workspace/$ws"
    if [[ -d "$agent_ws/.git" ]]; then
        su - "$user" -c "cd ~/workspace/$ws && git remote remove origin 2>/dev/null; git remote add origin file://$REPOS_DIR/$ws.git && git push -u origin main 2>/dev/null" 2>&1 | log_verbose || true
        log_ok "Git remote → $REPOS_DIR/$ws.git"
    fi

    # Set wake_channels: use channels from team.json if present, else role-based defaults
    dm_channel="$(dm_channel_name "$name")"
    tc="${AGENT_CHANNELS[$name]:-}"
    if [[ -n "$tc" && "$tc" != "null" && "$tc" != "[]" ]]; then
        wake_chs=$(echo "$tc" | jq -r --arg dm "$dm_channel" '. + [$dm] | unique | join(",")')
    else
        wake_chs="$dm_channel"
        case "${AGENT_ROLES[$name]:-}" in
            parent) wake_chs="$dm_channel,parents-n-bots" ;;
            kid)    wake_chs="$dm_channel,kids-n-bots" ;;
            ops|coo|dev) wake_chs="$dm_channel,general" ;;
        esac
    fi
    curl -sf -X PUT "http://127.0.0.1:$COMMS_PORT/api/agents/$name/config" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "{\"wake_channels\": \"$wake_chs\"}" > /dev/null 2>&1 || true
    log_ok "Wake channels → $wake_chs"

    # Copy template files (TEAM.md + soul) into agent workspace
    if [[ -n "$TEMPLATE_DIR" ]]; then
        if [[ -f "$TEMPLATE_DIR/TEAM.md" ]]; then
            # Inject template roles into TEAM_ROLES marker in agent's TEAM.md
            team_target="$agent_ws/TEAM.md"
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
            # Substitute default role names with actual agent names
            team_file="$agent_ws/TEAM.md"
            for aname in "${AGENTS[@]}"; do
                arole="${AGENT_ROLES[$aname]:-}"
                if [[ -n "$arole" && "$arole" != "$aname" ]]; then
                    sed -i "s/\\b${arole}\\b/${aname}/g" "$team_file"
                fi
            done
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

# ── Step 5b: Email MCP setup (non-interactive — config collected upfront) ──
if [[ ${#EMAIL_AGENTS[@]} -gt 0 ]]; then
    log_step "Step 5b: Email setup"

    # Build agent specs for install-email.sh (per-agent credentials)
    email_agent_args=()
    for name in "${EMAIL_AGENTS[@]}"; do
        token="${AGENT_TOKENS[$name]:-}"
        from="${EMAIL_FROM[$name]:-}"
        su="${EMAIL_SMTP_USER[$name]:-}"
        sp="${EMAIL_SMTP_PASS[$name]:-}"
        iu="${EMAIL_IMAP_USER[$name]:-}"
        ip="${EMAIL_IMAP_PASS[$name]:-}"
        email_agent_args+=(--agent "$name:$token:$from:$su:$sp:$iu:$ip")
    done

    # Ensure Node.js is available (required for fagents-mcp)
    if ! command -v node &>/dev/null; then
        echo "  Installing Node.js..."
        curl -fsSL https://deb.nodesource.com/setup_20.x 2>/dev/null | bash - 2>&1 | log_verbose
        apt-get install -y nodejs 2>&1 | log_verbose
        if command -v node &>/dev/null; then
            log_ok "Installed Node.js $(node --version)"
        else
            log_warn "Failed to install Node.js — email setup will fail"
        fi
    fi

    # Run install-email.sh
    SMTP_HOST="$smtp_host" \
    SMTP_PORT="$smtp_port" \
    IMAP_HOST="$imap_host" \
    IMAP_PORT="$imap_port" \
    bash "$SCRIPT_DIR/install-email.sh" \
        --port "$EMAIL_PORT" \
        --dir "$INFRA_HOME/workspace/fagents-mcp" \
        --user "$INFRA_USER" \
        "${email_agent_args[@]}"

    # Add fagents-mcp to each email agent's .mcp.json
    for name in "${EMAIL_AGENTS[@]}"; do
        user=$(agent_user "$name")
        ws="${AGENT_WORKSPACES[$name]}"
        agent_home=$(eval echo "~$user")
        agent_ws="$agent_home/workspace/$ws"
        token="${AGENT_TOKENS[$name]:-}"
        add_mcp_server "$agent_ws" "$user" "fagents-mcp" "http://127.0.0.1:$EMAIL_PORT/mcp" "$token"

        # Add email tool instructions to MEMORY.md
        from_addr="${EMAIL_FROM[$name]:-}"
        cat >> "$agent_ws/memory/MEMORY.md" <<EMAILEOF

## Email Tools
- You have email via MCP (fagents-mcp). Tools: send_email, read_email, list_emails, search_emails, list_mailboxes, download_attachment
- Your sending address: ${from_addr}
- Do NOT try to configure email yourself — it is already set up. Just call the tools directly
- Do NOT use Bash to search for MCP config, API keys, or ports — the tools are available in your tool list automatically
EMAILEOF
        chown "$user:fagent" "$agent_ws/memory/MEMORY.md"
        log_ok "$name: email configured"
    done
    EMAIL_CONFIGURED=1
fi

# ── Step 5c: Telegram setup (non-interactive — config collected upfront) ──
if [[ ${#TELEGRAM_AGENTS[@]} -gt 0 ]]; then
    log_step "Step 5c: Telegram setup"

    # Create credential store
    mkdir -p "$INFRA_HOME/.agents"
    for name in "${TELEGRAM_AGENTS[@]}"; do
        user=$(agent_user "$name")
        agent_dir="$INFRA_HOME/.agents/$user"
        mkdir -p "$agent_dir"

        # Write telegram.env
        cat > "$agent_dir/telegram.env" <<TGEOF
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN[$name]:-}
TELEGRAM_ALLOWED_IDS=${TELEGRAM_ALLOWED[$name]:-}
TGEOF

        # Write openai.env if key provided
        if [[ -n "$OPENAI_API_KEY" ]]; then
            cat > "$agent_dir/openai.env" <<OAEOF
OPENAI_API_KEY=$OPENAI_API_KEY
OAEOF
            chmod 600 "$agent_dir/openai.env"
        fi

        chown -R "$INFRA_USER:fagent" "$agent_dir"
        chmod 700 "$agent_dir"
        chmod 600 "$agent_dir/telegram.env"
    done
    log_ok "Telegram credentials stored in $INFRA_HOME/.agents/"

    # Sudoers rules — allow agents to run telegram.sh as fagents
    if [[ -n "$CLI_DIR" ]] && [[ -d "$CLI_DIR" ]]; then
        for name in "${TELEGRAM_AGENTS[@]}"; do
            user=$(agent_user "$name")
            # Skip agents that already have full sudo (bootstrap agents)
            [[ -n "${AGENT_BOOTSTRAP[$name]:-}" ]] && continue
            echo "$user ALL=($INFRA_USER) NOPASSWD: $CLI_DIR/telegram.sh, $CLI_DIR/tts-speak.sh, $CLI_DIR/stt-transcribe.sh" > "/etc/sudoers.d/${user}-telegram"
            chmod 440 "/etc/sudoers.d/${user}-telegram"
        done
        log_ok "Sudoers rules created for telegram.sh, tts-speak.sh, stt-transcribe.sh"
    fi

    # Add Telegram instructions to each agent's MEMORY.md
    for name in "${TELEGRAM_AGENTS[@]}"; do
        user=$(agent_user "$name")
        ws="${AGENT_WORKSPACES[$name]}"
        agent_home=$(eval echo "~$user")
        agent_ws="$agent_home/workspace/$ws"
        cat >> "$agent_ws/memory/MEMORY.md" <<TGMEMEOF

## Telegram
- You have Telegram via \`sudo -u fagents $CLI_DIR/telegram.sh\`
- Commands: \`whoami\`, \`send <chat-id> <message>\`, \`sendVoice <chat-id> <ogg-file>\`, \`poll\`
- The daemon collects incoming DMs automatically via \`collect_telegram()\`
- Use \`send\` to reply — the chat ID comes from the inbox message
- Voice output: \`sudo -u fagents $CLI_DIR/tts-speak.sh <chat-id> "text"\` — text to speech via OpenAI TTS, sent as Telegram voice message
- Voice input: incoming voice messages are automatically transcribed via Whisper and appear as text in your inbox
- Do NOT try to access bot tokens or API keys directly — credential isolation via sudo
TGMEMEOF
        chown "$user:fagent" "$agent_ws/memory/MEMORY.md"
        log_ok "$name: Telegram configured"
    done
    TELEGRAM_CONFIGURED=1
fi

# ── Step 5d: X (Twitter) setup (non-interactive — config collected upfront) ──
if [[ ${#X_AGENTS[@]} -gt 0 ]]; then
    log_step "Step 5d: X (Twitter) setup"

    mkdir -p "$INFRA_HOME/.agents"
    for name in "${X_AGENTS[@]}"; do
        user=$(agent_user "$name")
        agent_dir="$INFRA_HOME/.agents/$user"
        mkdir -p "$agent_dir"

        # Write x.env
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
            if [[ -z "${AGENT_BOOTSTRAP[$name]:-}" ]]; then
                if [[ -f "/etc/sudoers.d/${user}-telegram" ]]; then
                    existing=$(cat "/etc/sudoers.d/${user}-telegram")
                    echo "${existing}, $CLI_DIR/x.sh" > "/etc/sudoers.d/${user}-telegram"
                    chmod 440 "/etc/sudoers.d/${user}-telegram"
                else
                    echo "$user ALL=($INFRA_USER) NOPASSWD: $CLI_DIR/x.sh" > "/etc/sudoers.d/${user}-x"
                    chmod 440 "/etc/sudoers.d/${user}-x"
                fi
            fi
        fi

        # MEMORY.md
        ws="${AGENT_WORKSPACES[$name]}"
        agent_home=$(eval echo "~$user")
        agent_ws="$agent_home/workspace/$ws"
        cat >> "$agent_ws/memory/MEMORY.md" <<XMEMEOF

## X (Twitter)
- You have X (Twitter) via \`sudo -u fagents $CLI_DIR/x.sh\`
- Read commands: \`search <query>\`, \`tweet <id>\`, \`user <username>\`, \`tweets <username>\`
- Write commands: \`post <text>\`, \`reply <tweet-id> <text>\`
- X is on-demand — call it when you need it, no polling/daemon integration
- Do NOT try to access API keys or tokens directly — credential isolation via sudo
XMEMEOF
        chown "$user:fagent" "$agent_ws/memory/MEMORY.md"
        log_ok "$name: X configured"
    done
    X_CONFIGURED=1
fi

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
