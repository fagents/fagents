#!/bin/bash
# test-install.sh — E2E install test for fagents on a remote Linux host
#
# Fully non-interactive. Runnable by agents or humans.
# Runs the real installer from GitHub HEAD on a remote server,
# verifies the result, then cleans up.
# This is a post-push smoke test — use VM tests to gate commits.
#
# All remote work is batched into single SSH calls.
#
# Usage: bash test-install.sh
#
# Prerequisites: SSH access to TEST_HOST with sudo

set -uo pipefail

# ── Config ──
TEST_HOST="${TEST_HOST:?Set TEST_HOST (e.g. user@hostname)}"
COMMS_PORT="${COMMS_PORT:-19754}"
OPS_NAME="${OPS_NAME:-Alpha}"
COMMS_NAME="${COMMS_NAME:-Bravo}"
HUMAN_NAME="${HUMAN_NAME:-Tester}"
OPS_USER="$(echo "$OPS_NAME" | tr '[:upper:]' '[:lower:]')"
COMMS_USER="$(echo "$COMMS_NAME" | tr '[:upper:]' '[:lower:]')"

# ── TAP helpers ──
PASS=0
FAIL=0
TEST_NUM=0

TAP_FILE="/tmp/fagents-e2e-tap-$$"
: > "$TAP_FILE"

parse_tap() {
    while IFS= read -r line; do
        case "$line" in
            ok\ *)
                echo "$line"
                echo "P" >> "$TAP_FILE"
                ;;
            not\ ok\ *)
                echo "$line"
                echo "F" >> "$TAP_FILE"
                ;;
            \#*)
                echo "$line"
                ;;
        esac
    done
}

# SSH ControlMaster — all remote calls share one TCP connection
SSH_CTL="/tmp/fagents-e2e-ssh-$$"

ssh_start() {
    ssh -o BatchMode=yes -o ConnectTimeout=10 \
        -o ControlMaster=yes -o ControlPath="$SSH_CTL" -o ControlPersist=300 \
        -fN "$TEST_HOST"
}

ssh_stop() {
    ssh -o ControlPath="$SSH_CTL" -O exit "$TEST_HOST" 2>/dev/null || true
}

remote() {
    ssh -o BatchMode=yes -o ConnectTimeout=10 \
        -o ControlPath="$SSH_CTL" "$TEST_HOST" "$@"
}

# ── Cleanup ──
cleanup() {
    echo ""
    echo "=== Cleanup ==="
    remote "sudo bash -s" "$OPS_USER" "$COMMS_USER" "$COMMS_PORT" <<'CLEANEOF'
set +e
OPS_USER="$1"; COMMS_USER="$2"; COMMS_PORT="$3"
pkill -f "server.py serve.*--port $COMMS_PORT" 2>/dev/null; sleep 1
for user in "$OPS_USER" "$COMMS_USER"; do
    id "$user" &>/dev/null && { pkill -u "$user" 2>/dev/null; sleep 0.3; userdel -r "$user" 2>/dev/null; echo "  removed user: $user"; }
done
id fagents &>/dev/null && { pkill -9 -u fagents 2>/dev/null; sleep 1; userdel -r fagents 2>/dev/null; echo "  removed user: fagents"; }
sleep 1
if getent group fagent &>/dev/null; then
    groupdel fagent 2>/dev/null || sed -i '/^fagent:/d' /etc/group 2>/dev/null
    echo "  removed group: fagent"
fi
rm -f /etc/sudoers.d/"$OPS_USER" /etc/sudoers.d/"$COMMS_USER"
rm -f /etc/sudoers.d/"${COMMS_USER}-telegram" /etc/sudoers.d/"${COMMS_USER}-x"
rm -rf /home/fagents/.agents
git config --system --unset-all safe.directory 2>/dev/null
systemctl stop fagents 2>/dev/null; systemctl disable fagents 2>/dev/null; rm -f /etc/systemd/system/fagents.service
systemctl stop fagents-mcp 2>/dev/null; systemctl disable fagents-mcp 2>/dev/null; rm -f /etc/systemd/system/fagents-mcp.service
systemctl daemon-reload 2>/dev/null
rm -rf /tmp/fagents-install-* /tmp/fagents-e2e-*
echo "  cleanup done"
CLEANEOF
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

    # Run the real curl pipeline from GitHub HEAD (tests the actual user experience).
    # Installer starts comms via nohup which holds SSH FDs open, so we write a
    # wrapper script on the remote, run it backgrounded, and poll the log.
    INSTALL_LOG="/tmp/fagents-e2e-install.log"
    remote "cat > /tmp/fagents-e2e-run.sh" <<RUNEOF
#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/fagents/fagents/main/install.sh | \\
    sudo NONINTERACTIVE=1 \\
    OPS_AGENT_NAME='$OPS_NAME' \\
    COMMS_AGENT_NAME='$COMMS_NAME' \\
    HUMAN_NAMES_INPUT='$HUMAN_NAME' \\
    TELEGRAM_ENABLE=1 \\
    TELEGRAM_BOT_TOKEN_INPUT='test-dummy-token' \\
    TELEGRAM_ALLOWED_INPUT='12345' \\
    OPENAI_API_KEY_INPUT='test-dummy-openai-key' \\
    X_ENABLE=1 \\
    X_BEARER_TOKEN_INPUT='test-dummy-x-bearer' \\
    X_CONSUMER_KEY_INPUT='test-dummy-x-ck' \\
    X_CONSUMER_SECRET_INPUT='test-dummy-x-cs' \\
    X_ACCESS_TOKEN_INPUT='test-dummy-x-at' \\
    X_ACCESS_TOKEN_SECRET_INPUT='test-dummy-x-ats' \\
    bash -s -- \\
    --skip-claude-auth --comms-port $COMMS_PORT
RUNEOF
    remote "nohup bash /tmp/fagents-e2e-run.sh > $INSTALL_LOG 2>&1 &"

    # Poll log until installer finishes (marker line appears)
    echo "  Waiting for installer..."
    for i in $(seq 1 120); do
        sleep 2
        if remote "grep -q 'What now, hooman?' $INSTALL_LOG 2>/dev/null"; then
            remote "cat $INSTALL_LOG" 2>/dev/null
            break
        fi
        [[ $i -eq 120 ]] && { echo "  FATAL: installer timed out after 240s"; remote "cat $INSTALL_LOG" 2>/dev/null; return 1; }
    done

    # Wait for comms server to be ready
    for i in 1 2 3 4 5 6 7 8; do
        sleep 1
        if remote "curl -sf --max-time 3 http://127.0.0.1:$COMMS_PORT/api/health" >/dev/null 2>&1; then
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

    remote "sudo bash -s" "$COMMS_PORT" "$HUMAN_NAME" "$OPS_NAME" "$COMMS_NAME" "$OPS_USER" "$COMMS_USER" <<'VERIFYEOF' | parse_tap
#!/bin/bash
set +e
N=0
ok()     { N=$((N+1)); echo "ok $N - $1"; }
not_ok() { N=$((N+1)); echo "not ok $N - $1"; }
check()  {
    local desc="$1"; shift
    if eval "$*" >/dev/null 2>&1; then ok "$desc"; else not_ok "$desc"; fi
}

COMMS_PORT="$1"; HUMAN_NAME="$2"; OPS_NAME="$3"; COMMS_NAME="$4"; OPS_USER="$5"; COMMS_USER="$6"

# -- Users & groups --
check "fagent group exists"       'getent group fagent'
check "fagents infra user exists" 'id fagents'
check "fagents home dir exists"   'test -d /home/fagents'
check "$OPS_USER user exists"     "id $OPS_USER"
check "$OPS_USER in fagent group" "id -nG $OPS_USER | grep -qw fagent"
check "$COMMS_USER user exists"   "id $COMMS_USER"
check "$COMMS_USER in fagent group" "id -nG $COMMS_USER | grep -qw fagent"

# -- Infrastructure --
check "fagents-comms bare repo exists"       'test -d /home/fagents/repos/fagents-comms.git'
check "fagents-autonomy bare repo exists"    'test -d /home/fagents/repos/fagents-autonomy.git'
check "fagents-comms working copy exists"    'test -d /home/fagents/workspace/fagents-comms'
check "fagents-autonomy working copy exists" 'test -d /home/fagents/workspace/fagents-autonomy'
check "fagents-cli bare repo exists"         'test -d /home/fagents/repos/fagents-cli.git'
check "fagents-cli working copy exists"      'test -d /home/fagents/workspace/fagents-cli'
check "fagents-mcp bare repo exists"         'test -d /home/fagents/repos/fagents-mcp.git'
check "fagents-mcp working copy exists"      'test -d /home/fagents/workspace/fagents-mcp'
check "fagents-mcp bare has no origin"       '! sudo -u fagents git -C /home/fagents/repos/fagents-mcp.git remote | grep -q origin'
check "fagents bare repo exists"             'test -d /home/fagents/repos/fagents.git'
check "fagents working copy exists"          'test -d /home/fagents/workspace/fagents'

# -- Comms server --
check "comms health endpoint responds" "curl -sf --max-time 5 http://127.0.0.1:$COMMS_PORT/api/health"

# Extract token from ops agent's start-agent.sh
admin_token=$(grep -m1 'COMMS_TOKEN=' /home/$OPS_USER/workspace/$OPS_USER/start-agent.sh 2>/dev/null | sed 's/.*COMMS_TOKEN="\(.*\)"/\1/' | sed "s/.*COMMS_TOKEN='//" | sed "s/'$//") || true

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
    check "$COMMS_USER channel exists" "test -f /home/fagents/workspace/fagents-comms/channels/$COMMS_USER.log"
else
    not_ok "could not read admin token — skipping comms API checks"
fi

# -- Ops agent workspace --
ws="/home/$OPS_USER/workspace/$OPS_USER"
check "$OPS_NAME workspace exists"             "test -d $ws"
check "$OPS_NAME MEMORY.md exists"             "test -f $ws/memory/MEMORY.md"
check "$OPS_NAME SOUL.md exists"               "test -f $ws/memory/SOUL.md"
check "$OPS_NAME SOUL.md has ops content"      "grep -q 'bootstrap' $ws/memory/SOUL.md"
check "$OPS_NAME MEMORY.md has ops memory"     "grep -qi 'agent types' $ws/memory/MEMORY.md"
check "$OPS_NAME MEMORY.md has email security" "grep -q 'Email Security' $ws/memory/MEMORY.md"
check "$OPS_NAME .claude/settings.json exists" "test -f $ws/.claude/settings.json"
check "$OPS_NAME settings.json is valid JSON"  "jq . $ws/.claude/settings.json"
check "$OPS_NAME deny rules have absolute paths" "grep -q '/home/$OPS_USER/workspace/$OPS_USER/.env' $ws/.claude/settings.json"
check "$OPS_NAME TEAM.md exists"               "test -f $ws/TEAM.md"
check "$OPS_NAME start-agent.sh is executable" "test -x $ws/start-agent.sh"
check "$OPS_NAME .gitignore exists"            "test -f $ws/.gitignore"
check "$OPS_NAME git repo has commits"         "su -s /bin/bash $OPS_USER -c 'git -C $ws log --oneline -1'"
check "$OPS_NAME has full sudoers"             "test -f /etc/sudoers.d/$OPS_USER"
check "$OPS_NAME deploylog skill installed"   "test -f /home/$OPS_USER/.claude/skills/fagents-deploylog/SKILL.md"
check "$OPS_NAME deploylog skill resolved"    "! grep -q '__INFRA_HOME__' /home/$OPS_USER/.claude/skills/fagents-deploylog/SKILL.md"
check "$OPS_NAME MEMORY.md has deploylog"     "grep -q 'DEPLOYLOG automation' /home/$OPS_USER/workspace/$OPS_USER/memory/MEMORY.md"
check "$OPS_NAME deploylog cron exists"       "su -s /bin/bash $OPS_USER -c 'crontab -l' 2>/dev/null | grep -q 'deploylog-check'"
check "health-check.sh exists"                "test -x /home/fagents/workspace/fagents-autonomy/health-check.sh"
check "fagents user health cron exists"        "su -s /bin/bash fagents -c 'crontab -l' 2>/dev/null | grep -q 'health-check.sh'"
check "stop-team.sh has .stopped marker"       "grep -q 'daemon.stopped' /home/fagents/team/stop-team.sh"

# -- Comms agent workspace --
ws="/home/$COMMS_USER/workspace/$COMMS_USER"
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
check "$COMMS_NAME git repo has commits"         "su -s /bin/bash $COMMS_USER -c 'git -C $ws log --oneline -1'"
check "$COMMS_NAME does NOT have full sudoers"   "test ! -f /etc/sudoers.d/$COMMS_USER"

# -- Telegram credentials (comms agent only) --
check ".agents directory exists"                   'test -d /home/fagents/.agents'
check "$COMMS_USER telegram cred dir exists"       "test -d /home/fagents/.agents/$COMMS_USER"

dir_perms=$(stat -c %a /home/fagents/.agents/$COMMS_USER 2>/dev/null)
if [[ "$dir_perms" == "700" ]]; then ok "$COMMS_USER cred dir is 700"; else not_ok "$COMMS_USER cred dir is 700 (got: $dir_perms)"; fi

file_perms=$(stat -c %a /home/fagents/.agents/$COMMS_USER/telegram.env 2>/dev/null)
if [[ "$file_perms" == "600" ]]; then ok "$COMMS_USER telegram.env is 600"; else not_ok "$COMMS_USER telegram.env is 600 (got: $file_perms)"; fi

file_owner=$(stat -c %U /home/fagents/.agents/$COMMS_USER/telegram.env 2>/dev/null)
if [[ "$file_owner" == "fagents" ]]; then ok "$COMMS_USER telegram.env owned by fagents"; else not_ok "$COMMS_USER telegram.env owned by fagents (got: $file_owner)"; fi

if su - "$COMMS_USER" -c "cat /home/fagents/.agents/$COMMS_USER/telegram.env" 2>/dev/null; then
    not_ok "$COMMS_USER cannot read telegram.env directly"
else
    ok "$COMMS_USER cannot read telegram.env directly"
fi

check "$COMMS_USER telegram.env has token" "grep -q TELEGRAM_BOT_TOKEN /home/fagents/.agents/$COMMS_USER/telegram.env"
check "$COMMS_USER telegram.env has TELEGRAM_ALLOWED_IDS" "grep -q TELEGRAM_ALLOWED_IDS /home/fagents/.agents/$COMMS_USER/telegram.env"

# openai.env
check "$COMMS_USER openai.env exists" "test -f /home/fagents/.agents/$COMMS_USER/openai.env"
oai_perms=$(stat -c %a /home/fagents/.agents/$COMMS_USER/openai.env 2>/dev/null)
if [[ "$oai_perms" == "600" ]]; then ok "$COMMS_USER openai.env is 600"; else not_ok "$COMMS_USER openai.env is 600 (got: $oai_perms)"; fi
check "$COMMS_USER openai.env has OPENAI_API_KEY" "grep -q OPENAI_API_KEY /home/fagents/.agents/$COMMS_USER/openai.env"

# -- X credentials (comms agent only) --
check "$COMMS_USER x.env exists" "test -f /home/fagents/.agents/$COMMS_USER/x.env"
file_perms=$(stat -c %a /home/fagents/.agents/$COMMS_USER/x.env 2>/dev/null)
if [[ "$file_perms" == "600" ]]; then ok "$COMMS_USER x.env is 600"; else not_ok "$COMMS_USER x.env is 600 (got: $file_perms)"; fi
check "$COMMS_USER x.env has X_BEARER_TOKEN" "grep -q X_BEARER_TOKEN /home/fagents/.agents/$COMMS_USER/x.env"

# -- Sudoers: comms agent gets scoped rules --
check "${COMMS_USER}-telegram sudoers exists" "test -f /etc/sudoers.d/${COMMS_USER}-telegram"
check "${COMMS_USER}-telegram sudoers has telegram.sh" "grep -q telegram.sh /etc/sudoers.d/${COMMS_USER}-telegram"
check "${COMMS_USER}-telegram sudoers has tts-speak.sh" "grep -q tts-speak.sh /etc/sudoers.d/${COMMS_USER}-telegram"
check "${COMMS_USER}-telegram sudoers has x.sh" "grep -q x.sh /etc/sudoers.d/${COMMS_USER}-telegram"

# -- Ops agent has NO telegram/x creds --
check "ops agent has no telegram creds" "test ! -d /home/fagents/.agents/$OPS_USER"

# -- Team scripts --
check "start-fagents.sh exists and executable" 'test -x /home/fagents/team/start-fagents.sh'
check "stop-fagents.sh exists and executable"  'test -x /home/fagents/team/stop-fagents.sh'
check "restart-fagents.sh exists and executable" 'test -x /home/fagents/team/restart-fagents.sh'
check "start-comms.sh exists and executable"   'test -x /home/fagents/team/start-comms.sh'
check "stop-comms.sh exists and executable"    'test -x /home/fagents/team/stop-comms.sh'
check "add-email.sh exists and executable"     'test -x /home/fagents/team/add-email.sh'
check "install-agent.sh exists and executable" 'test -x /home/fagents/team/install-agent.sh'
check "fagents.service exists"                 'test -f /etc/systemd/system/fagents.service'
check "fagents.service enabled"                'systemctl is-enabled --quiet fagents'
VERIFYEOF
}

# ── Verify interactive agent ──
verify_interactive() {
    echo ""
    echo "=== Verify Interactive Agent ==="

    remote "sudo bash -s" "$COMMS_PORT" <<'INTEREOF' | parse_tap
set +e
N=0
ok()     { N=$((N+1)); echo "ok $N - $1"; }
not_ok() { N=$((N+1)); echo "not ok $N - $1"; }
check()  {
    local desc="$1"; shift
    if eval "$*" >/dev/null 2>&1; then ok "$desc"; else not_ok "$desc"; fi
}

COMMS_PORT="$1"
IUSER="scout"
INAME="Scout"

# Create interactive agent
useradd -m -g fagent -s /bin/bash "$IUSER" 2>/dev/null

# install-agent.sh is in the team dir (copied during install)
cp /home/fagents/team/install-agent.sh /tmp/fagents-install-agent.sh
chmod 755 /tmp/fagents-install-agent.sh

# Run as interactive agent
su - "$IUSER" -c "
    export NONINTERACTIVE=1
    export AGENT_NAME='$INAME'
    export WORKSPACE='$IUSER'
    export GIT_HOST='local'
    export COMMS_URL='http://127.0.0.1:$COMMS_PORT'
    export AUTONOMY_REPO='/home/fagents/repos/fagents-autonomy.git'
    export AUTONOMY_DIR='/home/fagents/workspace/fagents-autonomy'
    export AUTONOMY_SHARED=1
    export CLI_DIR='/home/fagents/workspace/fagents-cli'
    export AGENT_TYPE='interactive'
    bash /tmp/fagents-install-agent.sh
" > /dev/null 2>&1

# Verify
check "interactive user exists"          "id $IUSER"
check "interactive workspace exists"     "test -d /home/$IUSER/workspace/$IUSER"
check "interactive MEMORY.md exists"     "test -f /home/$IUSER/workspace/$IUSER/memory/MEMORY.md"
check "interactive no start-agent.sh"    "test ! -f /home/$IUSER/workspace/$IUSER/start-agent.sh"
check "fagents-comms skill installed"    "test -f /home/$IUSER/.claude/skills/fagents-comms/SKILL.md"
check "fagents-chat skill installed"     "test -f /home/$IUSER/.claude/skills/fagents-chat/SKILL.md"
check "fagents-watch skill installed"    "test -f /home/$IUSER/.claude/skills/fagents-watch/SKILL.md"
check "cron skill installed"             "test -f /home/$IUSER/.claude/skills/cron/SKILL.md"
check "skill has CLI path (not placeholder)" "grep -q '/home/fagents/workspace/fagents-cli' /home/$IUSER/.claude/skills/fagents-comms/SKILL.md"
check "skill has no __CLI_DIR__"         "! grep -q '__CLI_DIR__' /home/$IUSER/.claude/skills/fagents-comms/SKILL.md"
check "cron skill has autonomy path"     "grep -q '/home/fagents/workspace/fagents-autonomy' /home/$IUSER/.claude/skills/cron/SKILL.md"
check "cron skill has no __AUTONOMY_DIR__" "! grep -q '__AUTONOMY_DIR__' /home/$IUSER/.claude/skills/cron/SKILL.md"

# Cleanup interactive agent
pkill -u "$IUSER" 2>/dev/null; sleep 0.3
userdel -r "$IUSER" 2>/dev/null
rm -f /tmp/fagents-install-agent.sh
INTEREOF
}

# ── Verify cleanup ──
verify_clean() {
    echo ""
    echo "=== Verify Cleanup ==="

    remote "sudo bash -s" "$OPS_USER" "$COMMS_USER" <<'VCLEANEOF' | parse_tap
set +e
N=0
ok()     { N=$((N+1)); echo "ok $N - $1"; }
not_ok() { N=$((N+1)); echo "not ok $N - $1"; }

OPS_USER="$1"; COMMS_USER="$2"

! id fagents 2>/dev/null && ok "fagents user removed" || not_ok "fagents user removed"
! id "$OPS_USER" 2>/dev/null && ok "$OPS_USER user removed" || not_ok "$OPS_USER user removed"
! id "$COMMS_USER" 2>/dev/null && ok "$COMMS_USER user removed" || not_ok "$COMMS_USER user removed"
! getent group fagent 2>/dev/null && ok "fagent group removed" || not_ok "fagent group removed"
! curl -sf "http://127.0.0.1:19754/api/health" 2>/dev/null && ok "comms not running on test port" || not_ok "comms not running on test port"
test ! -d /home/fagents && ok "fagents home dir removed" || not_ok "fagents home dir removed"
test ! -f /etc/systemd/system/fagents.service && ok "fagents.service removed" || not_ok "fagents.service removed"
VCLEANEOF
}

# ── Main ──
echo "fagents E2E install test"
echo "  host: $TEST_HOST"
echo "  ops: $OPS_NAME ($OPS_USER)"
echo "  comms: $COMMS_NAME ($COMMS_USER)"
echo "  port: $COMMS_PORT"
echo ""

ssh_start
trap ssh_stop EXIT

if ! remote "echo ok" >/dev/null 2>&1; then
    echo "FATAL: cannot SSH to $TEST_HOST"
    exit 1
fi

cleanup
install
verify
verify_interactive
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
