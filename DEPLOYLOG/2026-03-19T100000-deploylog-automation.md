# DEPLOYLOG Automation — Deploy to Existing Installation

**Date:** 2026-03-19
**Repos changed:** fagents, fagents-cli

## Commits to pull

```
fagents:      f88d9002e4750296bac01d477255ba1323d966e9  fagents-deploylog: skill, cron, installer support, E2E tests
fagents-cli:  c2c6da844068b0489fdc3264fd912dfedc6fcc46  Add fagents-deploylog skill: teaches agents to check for new DEPLOYLOGs
```

New installs get this automatically. This doc is for existing deployments.

## What changed

- **fagents** — installer now clones the fagents repo (bare + working copy), installs skills for all agent types (was interactive-only), sets up daily DEPLOYLOG check cron for the ops agent.
- **fagents-cli** — new `fagents-deploylog/SKILL.md` skill: teaches agents to check for new DEPLOYLOGs by comparing bare repo vs working copy git state. Gated by human ACK.

## Prerequisites

None.

## Setup steps

All commands run as root on the fagents host.

```bash
INFRA_USER="fagents"
INFRA_HOME=$(eval echo "~$INFRA_USER")
```

### 1. Pull fagents-cli

```bash
sudo git -C "$INFRA_HOME/repos/fagents-cli.git" fetch "https://github.com/fagents/fagents-cli.git" main:main
sudo git -C "$INFRA_HOME/workspace/fagents-cli" pull
```

### 2. Clone fagents repo (bare + working copy)

This is likely the first time the fagents repo is on this machine.

```bash
# Bare repo
if [ ! -d "$INFRA_HOME/repos/fagents.git" ]; then
    sudo -u "$INFRA_USER" git clone --bare "https://github.com/fagents/fagents.git" "$INFRA_HOME/repos/fagents.git"
    sudo -u "$INFRA_USER" git -C "$INFRA_HOME/repos/fagents.git" remote remove origin 2>/dev/null || true
    echo "Cloned fagents.git"
else
    sudo git -C "$INFRA_HOME/repos/fagents.git" fetch "https://github.com/fagents/fagents.git" main:main
    echo "Updated fagents.git"
fi
sudo chmod -R g+rX "$INFRA_HOME/repos/fagents.git"

# Working copy
if [ ! -d "$INFRA_HOME/workspace/fagents" ]; then
    sudo -u "$INFRA_USER" git clone "$INFRA_HOME/repos/fagents.git" "$INFRA_HOME/workspace/fagents"
    echo "Created fagents working copy"
else
    sudo git -C "$INFRA_HOME/workspace/fagents" pull
    echo "Updated fagents working copy"
fi
```

### 3. Install fagents-deploylog skill for each agent

```bash
CLI_DIR="$INFRA_HOME/workspace/fagents-cli"

FAGENT_GID=$(getent group fagent | cut -d: -f3)
AGENT_USERS=$(getent passwd | awk -F: -v gid="$FAGENT_GID" '$4==gid {print $1}')

for USER in $AGENT_USERS; do
    SKILLS_DIR=$(eval echo "~$USER")/.claude/skills/fagents-deploylog
    [ -d "$(eval echo "~$USER")/.claude" ] || continue  # skip users without claude

    sudo mkdir -p "$SKILLS_DIR"
    sudo cp "$CLI_DIR/fagents-deploylog/SKILL.md" "$SKILLS_DIR/SKILL.md"

    # Replace path placeholder
    if sed --version 2>/dev/null | grep -q GNU; then
        sudo sed -i "s|__INFRA_HOME__|$INFRA_HOME|g" "$SKILLS_DIR/SKILL.md"
    else
        sudo sed -i '' "s|__INFRA_HOME__|$INFRA_HOME|g" "$SKILLS_DIR/SKILL.md"
    fi

    sudo chown -R "$USER:fagent" "$SKILLS_DIR"
    echo "$USER: fagents-deploylog skill installed"
done
```

### 4. Set up daily cron for the ops agent

Identify your ops agent (the one with full sudo):

```bash
# Find the ops agent — has full sudoers (ALL=(ALL))
for USER in $AGENT_USERS; do
    SUDOERS="/etc/sudoers.d/$USER"
    if [ -f "$SUDOERS" ] && grep -q 'ALL=(ALL)' "$SUDOERS"; then
        OPS_USER="$USER"
        break
    fi
done

echo "Ops agent: $OPS_USER"

AUTONOMY_DIR="$INFRA_HOME/workspace/fagents-autonomy"
OPS_HOME=$(eval echo "~$OPS_USER")
OPS_WS="$OPS_HOME/workspace/$OPS_USER"

sudo -u "$OPS_USER" bash -c "
    PROJECT_DIR='$OPS_WS' \
    bash '$AUTONOMY_DIR/cron.sh' add deploylog-check '0 9 * * *' \
        'Check for new DEPLOYLOGs. Use /fagents-deploylog to check. Never deploy without human ACK.'
"
```

### 5. No restart needed

The skill is loaded on the next daemon wake. The cron fires daily at 9am.

## Doctor

Verify the full setup is correct:

```bash
INFRA_USER="fagents"
INFRA_HOME=$(eval echo "~$INFRA_USER")

FAGENT_GID=$(getent group fagent | cut -d: -f3)
AGENT_USERS=$(getent passwd | awk -F: -v gid="$FAGENT_GID" '$4==gid {print $1}')

echo "=== Repos ==="
test -d "$INFRA_HOME/repos/fagents.git" && echo "ok: bare repo exists" || echo "FAIL: bare repo missing"
test -d "$INFRA_HOME/workspace/fagents" && echo "ok: working copy exists" || echo "FAIL: working copy missing"

echo ""
echo "=== Skill ==="
for USER in $AGENT_USERS; do
    SKILL="$(eval echo "~$USER")/.claude/skills/fagents-deploylog/SKILL.md"
    if [ -f "$SKILL" ]; then
        if grep -q '__INFRA_HOME__' "$SKILL"; then
            echo "FAIL: $USER has unresolved placeholder"
        else
            echo "ok: $USER skill installed and resolved"
        fi
    else
        [ -d "$(eval echo "~$USER")/.claude" ] && echo "FAIL: $USER missing skill" || echo "skip: $USER (no .claude dir)"
    fi
done

echo ""
echo "=== Cron ==="
for USER in $AGENT_USERS; do
    if sudo -u "$USER" crontab -l 2>/dev/null | grep -q 'deploylog-check'; then
        echo "ok: $USER has deploylog-check cron"
    fi
done

echo ""
echo "=== Git fetch test ==="
sudo git -C "$INFRA_HOME/repos/fagents.git" fetch "https://github.com/fagents/fagents.git" main:main 2>&1 && echo "ok: fetch works" || echo "FAIL: fetch failed"

echo ""
echo "=== Services ==="
curl -sf --max-time 5 http://127.0.0.1:9754/api/health > /dev/null && echo "ok: comms healthy" || echo "FAIL: comms not responding"
```

## How it works

1. Daily at 9am, cron fires → message lands in ops agent's inbox
2. Agent wakes on msgbeat, invokes `/fagents-deploylog` skill
3. Skill instructs: fetch bare repo from GitHub, diff against working copy HEAD
4. New DEPLOYLOG files found → agent reads them, posts summary on comms
5. Agent asks human operator for ACK — never auto-deploys
6. On ACK, agent reads DEPLOYLOG, executes steps, then pulls working copy (`--ff-only`) to mark as deployed

## Cleanup

To remove:
```bash
for USER in $AGENT_USERS; do
    sudo rm -rf "$(eval echo "~$USER")/.claude/skills/fagents-deploylog"
    sudo -u "$USER" crontab -l 2>/dev/null | grep -v 'deploylog-check' | sudo -u "$USER" crontab -
done
sudo rm -rf "$INFRA_HOME/repos/fagents.git" "$INFRA_HOME/workspace/fagents"
```
