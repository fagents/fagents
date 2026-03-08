#!/bin/bash
# install-team-macos.sh — Provision a team of agents on macOS
#
# Usage: sudo ./install-team-macos.sh [options] [AGENT1 AGENT2 ...]
#    or: sudo ./install-team-macos.sh --template business
#
# Each AGENT can be NAME or NAME:WORKSPACE
#   NAME only:       workspace defaults to <name lowercase>
#   NAME:WORKSPACE:  explicit workspace name
#
# Options:
#   --template NAME         Use a team template (e.g., business)
#   --comms-port PORT       Comms server port (default: 9754)
#   --comms-repo URL        fagents-comms git repo URL (default: GitHub)
#   --skip-claude-auth      Skip Claude Code authentication setup
#   --verbose               Show full output (default: summary only)
#
# Creates a 'fagents' infra user that owns the comms server and git repos.
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
TEMPLATE=""
AGENTS=()
HUMAN_NAMES=()
INFRA_USER="fagents"
INFRA_HOME="/Users/$INFRA_USER"

TELEGRAM_CONFIGURED=""
TELEGRAM_AGENTS=()
declare -A TELEGRAM_BOT_TOKEN
declare -A TELEGRAM_ALLOWED

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

# DM channel naming
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

# ── Telegram config (collected upfront, installed in Step 5b) ──
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
            local_var="TELEGRAM_BOT_TOKEN_${name^^}"
            if [[ -n "${!local_var:-}" ]]; then
                TELEGRAM_BOT_TOKEN[$name]="${!local_var}"
            elif [[ -z "${NONINTERACTIVE:-}" ]]; then
                read -rsp "    $name bot token: " _tg_token; echo ""
                TELEGRAM_BOT_TOKEN[$name]="$_tg_token"
            fi
        done

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
            for name in "${TELEGRAM_AGENTS[@]}"; do
                local_var="TELEGRAM_ALLOWED_${name^^}"
                if [[ -n "${!local_var:-}" ]]; then
                    TELEGRAM_ALLOWED[$name]="${!local_var}"
                else
                    TELEGRAM_ALLOWED[$name]="NONE"
                fi
            done
        fi
    fi
fi

echo ""
echo "  Infra user:  $INFRA_USER (owns comms + git repos)"
echo "  Agents:      ${AGENTS[*]}"
echo "  Humans:      ${HUMAN_NAMES[*]}"
echo "  Comms:       127.0.0.1:$COMMS_PORT"
[[ -n "$CLAUDE_TOKEN" ]] && echo "  Claude auth: provided" || echo "  Claude auth: skip (set up manually later)"
if [[ ${#TELEGRAM_AGENTS[@]} -gt 0 ]]; then
    echo "  Telegram:    enabled (${TELEGRAM_AGENTS[*]})"
else
    echo "  Telegram:    disabled"
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
for name in "${AGENT_NAMES[@]}"; do
    check_user_conflict "$(agent_user "$name")" "$name"
done

# Create infra user
if id "$INFRA_USER" &>/dev/null; then
    log_ok "$INFRA_USER (infra) already exists"
else
    create_user "$INFRA_USER"
    log_ok "Created $INFRA_USER (infra)"
fi

# Create agent users
for name in "${AGENT_NAMES[@]}"; do
    user=$(agent_user "$name")
    if id "$user" &>/dev/null; then
        log_ok "$user already exists"
    else
        create_user "$user"
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

# Generate TEAM.md from base template
BASE_TEAM_TEMPLATE="$SCRIPT_DIR/templates/base/TEAM.md"
if [[ -d "$SHARED_AUTONOMY_WORKING" ]] && [[ -f "$BASE_TEAM_TEMPLATE" ]]; then
    ROLES_BLOCK=""
    for name in "${AGENT_NAMES[@]}"; do
        role="${AGENT_ROLES[$name]:-agent}"
        ROLES_BLOCK+="- **$name** ($role)"$'\n'
    done
    _team_template=$(cat "$BASE_TEAM_TEMPLATE")
    TEAM_CONTENT="${_team_template/<!-- TEAM_ROLES -->/$ROLES_BLOCK}"
    sudo -Hu"$INFRA_USER" bash -c "cat > '$SHARED_AUTONOMY_WORKING/TEAM.md'" <<< "$TEAM_CONTENT"
    log_ok "TEAM.md generated from base template (untracked)"
fi

# Create bare git repos for each agent
for name in "${AGENT_NAMES[@]}"; do
    ws="${AGENT_WORKSPACES[$name]}"
    repo_path="$REPOS_DIR/$ws.git"
    if [[ -d "$repo_path" ]]; then
        log_ok "Repo $ws.git already exists"
    else
        sudo -Hu"$INFRA_USER" bash -lc "git init --bare -b main ~/repos/$ws.git" 2>&1 | log_verbose
        log_ok "Created bare repo: $ws.git"
    fi
done
# Make all repos group-writable with setgid
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

# ── Step 3: Register agents + human (CLI — before server starts) ──
log_step "Step 3: Register agents + human"
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

# ── Create channels with proper ACLs ──
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
        curl -sf -X PUT "http://127.0.0.1:$COMMS_PORT/api/channels/$ch/acl" \
            -H "Authorization: Bearer $_admin_token" \
            -H "Content-Type: application/json" \
            -d "{\"allow\": $allow}" > /dev/null 2>&1 || true
    done
    log_ok "Channels created with ACLs"
fi

# Subscribe via HTTP API
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

for name in "${AGENT_NAMES[@]}"; do
    user=$(agent_user "$name")
    ws="${AGENT_WORKSPACES[$name]}"
    token="${AGENT_TOKENS[$name]:-}"

    echo ""
    echo "  $name ($user):"

    sudo -Hu"$user" bash -lc "
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

    # Fix Claude project dir path (install-agent.sh hardcodes -home- but macOS uses /Users/)
    agent_home="/Users/$user"
    agent_ws="$agent_home/workspace/$ws"
    wrong_claude_dir="$agent_home/.claude/projects/-home-$user-workspace-$ws"
    right_claude_dir="$agent_home/.claude/projects/-Users-$user-workspace-$ws"
    if [[ -d "$wrong_claude_dir" && ! -d "$right_claude_dir" ]]; then
        mv "$wrong_claude_dir" "$right_claude_dir"
        # Fix .introspection-logs symlink
        if [[ -L "$agent_ws/.introspection-logs" ]]; then
            rm "$agent_ws/.introspection-logs"
            sudo -Hu"$user" bash -c "ln -s '$right_claude_dir' '$agent_ws/.introspection-logs'"
        fi
        log_ok "Fixed Claude project dir path for macOS"
    fi

    # Set up git remote pointing to local bare repo
    if [[ -d "$agent_ws/.git" ]]; then
        sudo -Hu"$user" bash -lc "cd ~/workspace/$ws && git remote remove origin 2>/dev/null; git remote add origin file://$REPOS_DIR/$ws.git && git push -u origin main 2>/dev/null" 2>&1 | log_verbose || true
        log_ok "Git remote → $REPOS_DIR/$ws.git"
    fi

    # Set wake_channels
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

    # Copy template files into agent workspace
    if [[ -n "$TEMPLATE_DIR" ]]; then
        if [[ -f "$TEMPLATE_DIR/TEAM.md" ]]; then
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
            # Substitute default role names with actual agent names (BSD sed)
            team_file="$agent_ws/TEAM.md"
            for aname in "${AGENTS[@]}"; do
                arole="${AGENT_ROLES[$aname]:-}"
                if [[ -n "$arole" && "$arole" != "$aname" ]]; then
                    sed -i '' "s/[[:<:]]${arole}[[:>:]]/${aname}/g" "$team_file"
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
        # Copy template prompt overrides
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

# ── Step 5b: Telegram setup (non-interactive — config collected upfront) ──
if [[ ${#TELEGRAM_AGENTS[@]} -gt 0 ]]; then
    log_step "Step 5b: Telegram setup"

    # Create credential store
    mkdir -p "$INFRA_HOME/.agents"
    for name in "${TELEGRAM_AGENTS[@]}"; do
        user=$(agent_user "$name")
        agent_dir="$INFRA_HOME/.agents/$user"
        mkdir -p "$agent_dir"

        cat > "$agent_dir/telegram.env" <<TGEOF
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN[$name]:-}
TELEGRAM_ALLOWED_IDS=${TELEGRAM_ALLOWED[$name]:-}
TGEOF

        chown -R "$INFRA_USER:fagent" "$agent_dir"
        chmod 700 "$agent_dir"
        chmod 600 "$agent_dir/telegram.env"
    done
    log_ok "Telegram credentials stored in $INFRA_HOME/.agents/"

    # Sudoers rules
    if [[ -n "$CLI_DIR" ]] && [[ -d "$CLI_DIR" ]]; then
        for name in "${TELEGRAM_AGENTS[@]}"; do
            user=$(agent_user "$name")
            [[ -n "${AGENT_BOOTSTRAP[$name]:-}" ]] && continue
            echo "$user ALL=($INFRA_USER) NOPASSWD: $CLI_DIR/telegram.sh" > "/etc/sudoers.d/${user}-telegram"
            chmod 440 "/etc/sudoers.d/${user}-telegram"
        done
        log_ok "Sudoers rules created for telegram.sh"
    fi

    # Add Telegram instructions to each agent's MEMORY.md
    for name in "${TELEGRAM_AGENTS[@]}"; do
        user=$(agent_user "$name")
        ws="${AGENT_WORKSPACES[$name]}"
        agent_home="/Users/$user"
        agent_ws="$agent_home/workspace/$ws"
        cat >> "$agent_ws/memory/MEMORY.md" <<TGMEMEOF

## Telegram
- You have Telegram via \`sudo -Hufagents $CLI_DIR/telegram.sh\`
- Commands: \`whoami\`, \`send <chat-id> <message>\`, \`poll\`
- The daemon collects incoming DMs automatically via \`collect_telegram()\`
- Use \`send\` to reply — the chat ID comes from the inbox message
- Do NOT try to access bot tokens directly — credential isolation via sudo
TGMEMEOF
        chown "$user:fagent" "$agent_ws/memory/MEMORY.md"
        log_ok "$name: Telegram configured"
    done
    TELEGRAM_CONFIGURED=1
fi

# ── Step 6: Claude Code setup ──
if [[ -z "$SKIP_CLAUDE_AUTH" ]]; then
    log_step "Step 6: Claude Code setup"

    for name in "${AGENT_NAMES[@]}"; do
        user=$(agent_user "$name")
        if sudo -Hu"$user" bash -lc "command -v claude" &>/dev/null; then
            log_ok "$name: Claude Code already installed"
        else
            echo "  $name: Installing Claude Code..."
            sudo -Hu"$user" bash -lc "curl -fsSL https://claude.ai/install.sh | bash" 2>&1 | tail -3 | log_verbose
            if sudo -Hu"$user" bash -lc "command -v claude" &>/dev/null; then
                log_ok "$name: Claude Code installed"
            else
                log_warn " Claude Code installation failed for $name"
            fi
        fi
    done

    if [[ -n "$CLAUDE_TOKEN" ]]; then
        for name in "${AGENT_NAMES[@]}"; do
            user=$(agent_user "$name")
            ws="${AGENT_WORKSPACES[$name]}"
            agent_home="/Users/$user"
            agent_ws="$agent_home/workspace/$ws"

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
for name in "${AGENT_NAMES[@]}"; do
    user=$(agent_user "$name")
    ws="${AGENT_WORKSPACES[$name]}"
    cat >> "$TEAM_DIR/start-team.sh" << AGENTSTART
echo "Starting $name..."
sudo -Hu"$user" bash -lc "cd ~/workspace/$ws && ./start-agent.sh" || echo "  WARNING: failed to start $name"
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
    user_home="/Users/$user"
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

log_ok "Created $TEAM_DIR/{start,stop}-{fagents,team,comms}.sh"

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
