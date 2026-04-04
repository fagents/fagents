#!/bin/bash
# test-install-macos.sh — E2E install test for fagents on macOS
#
# Runs locally (no SSH). Uses a non-default comms port to avoid conflicts.
# Fully non-interactive. Runnable by agents or humans.
#
# Usage: sudo bash test-install-macos.sh
#
# Prerequisites: Must run on macOS as root. Bash 4+ required.

set -uo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "FATAL: This test only runs on macOS"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "FATAL: Must run as root (sudo)"
    exit 1
fi

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "FATAL: bash 4+ required. Run: sudo /opt/homebrew/bin/bash $0"
    exit 1
fi

# ── Config ──
COMMS_PORT="${COMMS_PORT:-19754}"
OPS_NAME="${OPS_NAME:-Alpha}"
COMMS_NAME="${COMMS_NAME:-Bravo}"
HUMAN_NAME="${HUMAN_NAME:-Tester}"
OPS_USER="$(echo "$OPS_NAME" | tr '[:upper:]' '[:lower:]')"
COMMS_USER="$(echo "$COMMS_NAME" | tr '[:upper:]' '[:lower:]')"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/fagents"

# ── TAP helpers ──
TAP_FILE="/tmp/fagents-e2e-macos-tap-$$"
: > "$TAP_FILE"
N=0

ok()     { N=$((N+1)); echo "ok $N - $1"; echo "P" >> "$TAP_FILE"; }
not_ok() { N=$((N+1)); echo "not ok $N - $1"; echo "F" >> "$TAP_FILE"; }
check()  {
    local desc="$1"; shift
    if eval "$*" >/dev/null 2>&1; then ok "$desc"; else not_ok "$desc"; fi
}

# ── Cleanup ──
cleanup() {
    echo ""
    echo "=== Cleanup ==="
    set +e
    pkill -f "server.py serve.*--port $COMMS_PORT" 2>/dev/null; sleep 1
    for user in "$OPS_USER" "$COMMS_USER"; do
        if id "$user" &>/dev/null; then
            pkill -u "$user" 2>/dev/null; sleep 0.3
            dscl . -delete /Users/"$user" 2>/dev/null
            rm -rf /Users/"$user"
            rm -f /etc/sudoers.d/"$user" /etc/sudoers.d/"${user}-telegram" /etc/sudoers.d/"${user}-x" /etc/sudoers.d/"${user}-whatsapp"
            echo "  removed user: $user"
        fi
    done
    if id fagents &>/dev/null; then
        pkill -9 -u fagents 2>/dev/null; sleep 1
        dscl . -delete /Users/fagents 2>/dev/null
        rm -rf /Users/fagents
        echo "  removed user: fagents"
    fi
    sleep 1
    if dscl . -read /Groups/fagent &>/dev/null; then
        dscl . -delete /Groups/fagent 2>/dev/null
        echo "  removed group: fagent"
    fi
    rm -f /etc/sudoers.d/"$OPS_USER" /etc/sudoers.d/"$COMMS_USER"
    rm -f /etc/sudoers.d/"${COMMS_USER}-telegram" /etc/sudoers.d/"${COMMS_USER}-x" /etc/sudoers.d/"${COMMS_USER}-whatsapp"
    git config --system --unset-all safe.directory 2>/dev/null || true
    launchctl bootout system /Library/LaunchDaemons/ai.fagents.plist 2>/dev/null || true
    rm -f /Library/LaunchDaemons/ai.fagents.plist
    rm -rf /tmp/fagents-install-*
    echo "  cleanup done"
    set -uo pipefail
}

# ── Install ──
install() {
    echo ""
    echo "=== Install ==="
    echo "  ops: $OPS_NAME ($OPS_USER)"
    echo "  comms: $COMMS_NAME ($COMMS_USER)"
    echo "  comms port: $COMMS_PORT"
    echo "  human: $HUMAN_NAME"
    echo ""

    NONINTERACTIVE=1 \
    OPS_AGENT_NAME="$OPS_NAME" \
    COMMS_AGENT_NAME="$COMMS_NAME" \
    HUMAN_NAMES_INPUT="$HUMAN_NAME" \
    TELEGRAM_ENABLE=1 \
    TELEGRAM_BOT_TOKEN_INPUT="test-dummy-token" \
    TELEGRAM_ALLOWED_INPUT="12345" \
    OPENAI_API_KEY_INPUT="test-dummy-openai-key" \
    X_ENABLE=1 \
    X_BEARER_TOKEN_INPUT="test-dummy-x-bearer" \
    X_CONSUMER_KEY_INPUT="test-dummy-x-ck" \
    X_CONSUMER_SECRET_INPUT="test-dummy-x-cs" \
    X_ACCESS_TOKEN_INPUT="test-dummy-x-at" \
    X_ACCESS_TOKEN_SECRET_INPUT="test-dummy-x-ats" \
    WHATSAPP_ENABLE=1 \
    WHATSAPP_SELF_JID_INPUT="358445150070@s.whatsapp.net" \
    /opt/homebrew/bin/bash "$SCRIPT_DIR/install-team-macos.sh" \
        --skip-claude-auth --comms-port "$COMMS_PORT"

    # Wait for comms server to be ready
    for i in 1 2 3 4 5 6 7 8; do
        sleep 1
        if curl -sf --max-time 3 "http://127.0.0.1:$COMMS_PORT/api/health" >/dev/null 2>&1; then
            echo "  Comms server ready"
            break
        fi
        [[ $i -eq 8 ]] && echo "  WARNING: comms server not responding after 8s"
    done
}

# ── Verify ──
verify() {
    echo ""
    echo "=== Verify ==="

    # -- Users & groups (dscl-based) --
    check "fagent group exists"       'dscl . -read /Groups/fagent'
    check "fagents infra user exists" 'id fagents'
    check "fagents home dir exists"   'test -d /Users/fagents'
    check "$OPS_USER user exists"     "id $OPS_USER"
    check "$OPS_USER in fagent group" "id -nG $OPS_USER | grep -qw fagent"
    check "$OPS_USER is hidden"       "dscl . -read /Users/$OPS_USER IsHidden | grep -q 1"
    check "$COMMS_USER user exists"   "id $COMMS_USER"
    check "$COMMS_USER in fagent group" "id -nG $COMMS_USER | grep -qw fagent"
    check "$COMMS_USER is hidden"     "dscl . -read /Users/$COMMS_USER IsHidden | grep -q 1"

    # -- Home dir permissions (must be 750) --
    for user in "$OPS_USER" "$COMMS_USER"; do
        dir_perms=$(stat -f %A /Users/"$user" 2>/dev/null)
        if [[ "$dir_perms" == "750" ]]; then ok "$user home dir is 750"; else not_ok "$user home dir is 750 (got: $dir_perms)"; fi
    done

    # -- Infrastructure --
    check "fagents-comms bare repo exists"       'test -d /Users/fagents/repos/fagents-comms.git'
    check "fagents-autonomy bare repo exists"    'test -d /Users/fagents/repos/fagents-autonomy.git'
    check "fagents-comms working copy exists"    'test -d /Users/fagents/workspace/fagents-comms'
    check "fagents-autonomy working copy exists" 'test -d /Users/fagents/workspace/fagents-autonomy'
    check "fagents-cli bare repo exists"         'test -d /Users/fagents/repos/fagents-cli.git'
    check "fagents-cli working copy exists"      'test -d /Users/fagents/workspace/fagents-cli'
    check "fagents-mcp bare repo exists"         'test -d /Users/fagents/repos/fagents-mcp.git'
    check "fagents-mcp working copy exists"      'test -d /Users/fagents/workspace/fagents-mcp'
    check "fagents bare repo exists"             'test -d /Users/fagents/repos/fagents.git'
    check "fagents working copy exists"          'test -d /Users/fagents/workspace/fagents'

    # -- Comms server --
    check "comms health endpoint responds" "curl -sf --max-time 5 http://127.0.0.1:$COMMS_PORT/api/health"

    # Extract token from ops agent's start-agent.sh
    admin_token=$(grep -m1 'COMMS_TOKEN=' /Users/$OPS_USER/workspace/$OPS_USER/start-agent.sh 2>/dev/null | sed 's/.*COMMS_TOKEN="\(.*\)"/\1/' | sed "s/.*COMMS_TOKEN='//" | sed "s/'$//") || true

    if [[ -n "$admin_token" && "$admin_token" != "null" ]]; then
        AUTH="Authorization: Bearer $admin_token"
        WHOAMI=$(curl -sf --max-time 5 -H "$AUTH" "http://127.0.0.1:$COMMS_PORT/api/whoami")

        check "agents registered in comms" "echo '$WHOAMI' | jq -e '.agents | length > 0'"
        check "$OPS_NAME registered in comms" "echo '$WHOAMI' | jq -e '.agents[] | select(. == \"$OPS_NAME\")'"
        check "$COMMS_NAME registered in comms" "echo '$WHOAMI' | jq -e '.agents[] | select(. == \"$COMMS_NAME\")'"
        check "$HUMAN_NAME registered in comms" "echo '$WHOAMI' | jq -e '.agents[] | select(. == \"$HUMAN_NAME\")'"

        CHANNELS=$(curl -sf --max-time 5 -H "$AUTH" "http://127.0.0.1:$COMMS_PORT/api/channels")
        check "general channel exists" "echo '$CHANNELS' | jq -e '.[] | select(.name == \"general\")'"
        check "$OPS_USER channel exists" "echo '$CHANNELS' | jq -e '.[] | select(.name == \"$OPS_USER\")'"
        check "$COMMS_USER channel exists" "test -f /Users/fagents/.agents/comms/channels/$COMMS_USER.log"
    else
        not_ok "could not read admin token — skipping comms API checks"
    fi

    # -- Ops agent workspace --
    ws="/Users/$OPS_USER/workspace/$OPS_USER"
    check "$OPS_NAME workspace exists"             "test -d $ws"
    check "$OPS_NAME MEMORY.md exists"             "test -f $ws/memory/MEMORY.md"
    check "$OPS_NAME SOUL.md exists"               "test -f $ws/memory/SOUL.md"
    check "$OPS_NAME SOUL.md has ops content"      "grep -q 'bootstrap' $ws/memory/SOUL.md"
    check "$OPS_NAME MEMORY.md has ops memory"     "grep -qi 'agent types' $ws/memory/MEMORY.md"
    check "$OPS_NAME MEMORY.md has email security" "grep -q 'Email Security' $ws/memory/MEMORY.md"
    check "$OPS_NAME .claude/settings.json exists" "test -f $ws/.claude/settings.json"
    check "$OPS_NAME settings.json is valid JSON"  "jq . $ws/.claude/settings.json"
    check "$OPS_NAME TEAM.md exists"               "test -f $ws/TEAM.md"
    check "$OPS_NAME start-agent.sh is executable" "test -x $ws/start-agent.sh"
    check "$OPS_NAME .gitignore exists"            "test -f $ws/.gitignore"
    check "$OPS_NAME git repo has commits"         "sudo -Hu$OPS_USER bash -lc 'git -C $ws log --oneline -1'"
    check "$OPS_NAME has full sudoers"             "test -f /etc/sudoers.d/$OPS_USER"
    check "$OPS_NAME deploylog skill installed"   "test -f /Users/$OPS_USER/.claude/skills/fagents-deploylog/SKILL.md"
    check "$OPS_NAME deploylog skill resolved"    "! grep -q '__INFRA_HOME__' /Users/$OPS_USER/.claude/skills/fagents-deploylog/SKILL.md"
    check "$OPS_NAME MEMORY.md has deploylog"     "grep -q 'DEPLOYLOG automation' /Users/$OPS_USER/workspace/$OPS_USER/memory/MEMORY.md"
    check "$OPS_NAME deploylog cron exists"       "sudo -Hu$OPS_USER bash -lc 'crontab -l' 2>/dev/null | grep -q 'deploylog-check'"
    check "health-check.sh exists"                "test -x /Users/fagents/workspace/fagents-autonomy/health-check.sh"
    check "fagents user health cron exists"        "sudo -Hufagents bash -lc 'crontab -l' 2>/dev/null | grep -q 'health-check.sh'"
    check "stop-team.sh has .stopped marker"       "grep -q 'daemon.stopped' /Users/fagents/team/stop-team.sh"

    # -- Comms agent workspace --
    ws="/Users/$COMMS_USER/workspace/$COMMS_USER"
    check "$COMMS_NAME workspace exists"             "test -d $ws"
    check "$COMMS_NAME MEMORY.md exists"             "test -f $ws/memory/MEMORY.md"
    check "$COMMS_NAME SOUL.md exists"               "test -f $ws/memory/SOUL.md"
    check "$COMMS_NAME SOUL.md has comms content"    "grep -q 'colleague' $ws/memory/SOUL.md"
    check "$COMMS_NAME MEMORY.md has comms memory"   "grep -q 'Telegram' $ws/memory/MEMORY.md"
    check "$COMMS_NAME MEMORY.md has email security" "grep -q 'Email Security' $ws/memory/MEMORY.md"
    check "$COMMS_NAME .claude/settings.json exists" "test -f $ws/.claude/settings.json"
    check "$COMMS_NAME settings.json is valid JSON"  "jq . $ws/.claude/settings.json"
    check "$COMMS_NAME TEAM.md exists"               "test -f $ws/TEAM.md"
    check "$COMMS_NAME start-agent.sh is executable" "test -x $ws/start-agent.sh"
    check "$COMMS_NAME .gitignore exists"            "test -f $ws/.gitignore"
    check "$COMMS_NAME git repo has commits"         "sudo -Hu$COMMS_USER bash -lc 'git -C $ws log --oneline -1'"
    check "$COMMS_NAME does NOT have full sudoers"   "test ! -f /etc/sudoers.d/$COMMS_USER"

    # -- Cross-agent isolation --
    if sudo -Hu"$OPS_USER" bash -c "cat /Users/$COMMS_USER/workspace/$COMMS_USER/.env" 2>/dev/null; then
        not_ok "$OPS_USER cannot read $COMMS_USER's .env"
    else
        ok "$OPS_USER cannot read $COMMS_USER's .env"
    fi

    # -- Telegram credentials (comms agent only) --
    check ".agents directory exists"              'test -d /Users/fagents/.agents'
    check "$COMMS_USER telegram cred dir exists"  "test -d /Users/fagents/.agents/$COMMS_USER"

    dir_perms=$(stat -f %A /Users/fagents/.agents/"$COMMS_USER" 2>/dev/null)
    if [[ "$dir_perms" == "700" ]]; then ok "$COMMS_USER cred dir is 700"; else not_ok "$COMMS_USER cred dir is 700 (got: $dir_perms)"; fi

    file_perms=$(stat -f %A /Users/fagents/.agents/"$COMMS_USER"/telegram.env 2>/dev/null)
    if [[ "$file_perms" == "600" ]]; then ok "$COMMS_USER telegram.env is 600"; else not_ok "$COMMS_USER telegram.env is 600 (got: $file_perms)"; fi

    file_owner=$(stat -f %Su /Users/fagents/.agents/"$COMMS_USER"/telegram.env 2>/dev/null)
    if [[ "$file_owner" == "fagents" ]]; then ok "$COMMS_USER telegram.env owned by fagents"; else not_ok "$COMMS_USER telegram.env owned by fagents (got: $file_owner)"; fi

    if sudo -Hu"$COMMS_USER" bash -c "cat /Users/fagents/.agents/$COMMS_USER/telegram.env" 2>/dev/null; then
        not_ok "$COMMS_USER cannot read telegram.env directly"
    else
        ok "$COMMS_USER cannot read telegram.env directly"
    fi

    # Cross-agent isolation on creds
    if sudo -Hu"$OPS_USER" bash -c "cat /Users/fagents/.agents/$COMMS_USER/telegram.env" 2>/dev/null; then
        not_ok "$OPS_USER cannot read $COMMS_USER's telegram.env"
    else
        ok "$OPS_USER cannot read $COMMS_USER's telegram.env"
    fi

    check "$COMMS_USER telegram.env has token" "grep -q TELEGRAM_BOT_TOKEN /Users/fagents/.agents/$COMMS_USER/telegram.env"
    check "$COMMS_USER telegram.env has TELEGRAM_ALLOWED_IDS" "grep -q TELEGRAM_ALLOWED_IDS /Users/fagents/.agents/$COMMS_USER/telegram.env"

    # openai.env
    check "$COMMS_USER openai.env exists" "test -f /Users/fagents/.agents/$COMMS_USER/openai.env"
    oai_perms=$(stat -f %A /Users/fagents/.agents/"$COMMS_USER"/openai.env 2>/dev/null)
    if [[ "$oai_perms" == "600" ]]; then ok "$COMMS_USER openai.env is 600"; else not_ok "$COMMS_USER openai.env is 600 (got: $oai_perms)"; fi
    check "$COMMS_USER openai.env has OPENAI_API_KEY" "grep -q OPENAI_API_KEY /Users/fagents/.agents/$COMMS_USER/openai.env"

    # -- X credentials (comms agent only) --
    check "$COMMS_USER x.env exists" "test -f /Users/fagents/.agents/$COMMS_USER/x.env"
    file_perms=$(stat -f %A /Users/fagents/.agents/"$COMMS_USER"/x.env 2>/dev/null)
    if [[ "$file_perms" == "600" ]]; then ok "$COMMS_USER x.env is 600"; else not_ok "$COMMS_USER x.env is 600 (got: $file_perms)"; fi
    check "$COMMS_USER x.env has X_BEARER_TOKEN" "grep -q X_BEARER_TOKEN /Users/fagents/.agents/$COMMS_USER/x.env"

    # -- WhatsApp credentials (comms agent only) --
    check "$COMMS_USER whatsapp.env exists" "test -f /Users/fagents/.agents/$COMMS_USER/whatsapp.env"
    file_perms=$(stat -f %A /Users/fagents/.agents/"$COMMS_USER"/whatsapp.env 2>/dev/null)
    if [[ "$file_perms" == "600" ]]; then ok "$COMMS_USER whatsapp.env is 600"; else not_ok "$COMMS_USER whatsapp.env is 600 (got: $file_perms)"; fi
    check "$COMMS_USER whatsapp.env has WHATSAPP_ALLOWED_JIDS" "grep -q WHATSAPP_ALLOWED_JIDS /Users/fagents/.agents/$COMMS_USER/whatsapp.env"
    check "$COMMS_USER whatsapp.env has WHATSAPP_SELF_JID" "grep -q WHATSAPP_SELF_JID /Users/fagents/.agents/$COMMS_USER/whatsapp.env"
    check "$COMMS_USER whatsapp-spool dir exists" "test -d /Users/fagents/.agents/$COMMS_USER/whatsapp-spool"
    check "$COMMS_USER whatsapp-outbox dir exists" "test -d /Users/fagents/.agents/$COMMS_USER/whatsapp-outbox"
    check "$COMMS_USER whatsapp-session dir exists" "test -d /Users/fagents/.agents/$COMMS_USER/whatsapp-session"

    # -- Sudoers: comms agent gets scoped rules --
    check "${COMMS_USER}-telegram sudoers exists" "test -f /etc/sudoers.d/${COMMS_USER}-telegram"
    check "${COMMS_USER}-telegram sudoers has telegram.sh" "grep -q telegram.sh /etc/sudoers.d/${COMMS_USER}-telegram"
    check "${COMMS_USER}-telegram sudoers has tts-speak.sh" "grep -q tts-speak.sh /etc/sudoers.d/${COMMS_USER}-telegram"
    check "${COMMS_USER}-telegram sudoers has x.sh" "grep -q x.sh /etc/sudoers.d/${COMMS_USER}-telegram"
    check "${COMMS_USER}-telegram sudoers has whatsapp.mjs" "grep -q whatsapp.mjs /etc/sudoers.d/${COMMS_USER}-telegram"

    # Ops agent has NO telegram/x creds
    check "ops agent has no telegram creds" "test ! -d /Users/fagents/.agents/$OPS_USER"

    # -- Team scripts --
    check "start-fagents.sh exists and executable" 'test -x /Users/fagents/team/start-fagents.sh'
    check "stop-fagents.sh exists and executable"  'test -x /Users/fagents/team/stop-fagents.sh'
    check "start-comms.sh exists and executable"   'test -x /Users/fagents/team/start-comms.sh'
    check "stop-comms.sh exists and executable"    'test -x /Users/fagents/team/stop-comms.sh'
    check "add-email.sh exists and executable"     'test -x /Users/fagents/team/add-email.sh'
    check "launchd plist exists"                   'test -f /Library/LaunchDaemons/ai.fagents.plist'
}

# ── Verify cleanup ──
verify_clean() {
    echo ""
    echo "=== Verify Cleanup ==="

    ! id fagents 2>/dev/null && ok "fagents user removed" || not_ok "fagents user removed"
    ! id "$OPS_USER" 2>/dev/null && ok "$OPS_USER user removed" || not_ok "$OPS_USER user removed"
    ! id "$COMMS_USER" 2>/dev/null && ok "$COMMS_USER user removed" || not_ok "$COMMS_USER user removed"
    ! dscl . -read /Groups/fagent 2>/dev/null && ok "fagent group removed" || not_ok "fagent group removed"
    ! curl -sf "http://127.0.0.1:$COMMS_PORT/api/health" 2>/dev/null && ok "comms not running on test port" || not_ok "comms not running on test port"
    test ! -d /Users/fagents && ok "fagents home dir removed" || not_ok "fagents home dir removed"
    for user in "$OPS_USER" "$COMMS_USER"; do
        test ! -d /Users/"$user" && ok "$user home dir removed" || not_ok "$user home dir removed"
        test ! -f /etc/sudoers.d/"$user" && ok "$user sudoers removed" || not_ok "$user sudoers removed"
        test ! -f /etc/sudoers.d/"${user}-telegram" && ok "$user-telegram sudoers removed" || not_ok "$user-telegram sudoers removed"
    done
    test ! -f /Library/LaunchDaemons/ai.fagents.plist && ok "launchd plist removed" || not_ok "launchd plist removed"
}

# ── Main ──
echo "fagents E2E install test (macOS)"
echo "  ops: $OPS_NAME ($OPS_USER)"
echo "  comms: $COMMS_NAME ($COMMS_USER)"
echo "  port: $COMMS_PORT"
echo ""

cleanup
install
verify
cleanup
verify_clean

# ── Report ──
echo ""
echo "========================="
PASS=$(grep -c '^P$' "$TAP_FILE" 2>/dev/null) || PASS=0
FAIL=$(grep -c '^F$' "$TAP_FILE" 2>/dev/null) || FAIL=0
TOTAL=$((PASS + FAIL))
rm -f "$TAP_FILE"
if [[ $FAIL -eq 0 ]]; then
    echo "# $TOTAL/$TOTAL passed"
    exit 0
else
    echo "# $PASS/$TOTAL passed, $FAIL failed"
    exit 1
fi
