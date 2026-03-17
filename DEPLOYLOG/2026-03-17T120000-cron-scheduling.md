# Agent Cron Scheduling — Deploy to Existing Installation

**Date:** 2026-03-17
**Repos changed:** fagents-autonomy, fagents-cli, fagents

New installs get this automatically via the installer. This doc is for existing deployments.

## What changed

- **fagents-autonomy** — new `cron.sh`: agents schedule recurring messages to their own inbox via system cron. Messages wake the daemon on a normal msgbeat.
- **fagents-cli** — new `cron/SKILL.md`: teaches agents how to use cron scheduling (add/list/remove, cron syntax guide, examples).
- **fagents** — `install-agent.sh` installs the cron skill and replaces `__AUTONOMY_DIR__` placeholder in skill files.

## Prerequisites

None. Uses system cron (POSIX, available on all platforms).

## Setup steps

All commands run as root (or with sudo) on the fagents host.

```bash
INFRA_USER="fagents"
INFRA_HOME=$(eval echo "~$INFRA_USER")
```

### 1. Pull repos

```bash
for repo in fagents-autonomy fagents-cli; do
    sudo git -C "$INFRA_HOME/repos/${repo}.git" fetch "https://github.com/fagents/${repo}.git" main:main
    sudo git -C "$INFRA_HOME/workspace/${repo}" pull
done
```

### 2. Install cron skill for each agent

The skill file needs `__AUTONOMY_DIR__` replaced with the actual path. For **each agent** that should have cron:

```bash
AUTONOMY_DIR="$INFRA_HOME/workspace/fagents-autonomy"
CLI_DIR="$INFRA_HOME/workspace/fagents-cli"

# Find all agent users in the fagent group
FAGENT_GID=$(getent group fagent | cut -d: -f3)
AGENT_USERS=$(getent passwd | awk -F: -v gid="$FAGENT_GID" '$4==gid {print $1}')

for USER in $AGENT_USERS; do
    SKILLS_DIR=$(eval echo "~$USER")/.claude/skills/cron
    [ -d "$(eval echo "~$USER")/.claude" ] || continue  # skip users without claude

    sudo mkdir -p "$SKILLS_DIR"
    sudo cp "$CLI_DIR/cron/SKILL.md" "$SKILLS_DIR/SKILL.md"

    # Replace path placeholder
    if sed --version 2>/dev/null | grep -q GNU; then
        sudo sed -i "s|__AUTONOMY_DIR__|$AUTONOMY_DIR|g" "$SKILLS_DIR/SKILL.md"
    else
        sudo sed -i '' "s|__AUTONOMY_DIR__|$AUTONOMY_DIR|g" "$SKILLS_DIR/SKILL.md"
    fi

    sudo chown -R "$USER:fagent" "$SKILLS_DIR"
    echo "$USER: cron skill installed"
done
```

### 3. No restart needed

The skill is loaded on the next daemon wake. No restart required.

## How it works

1. Agent calls `cron.sh add <handle> "<schedule>" "<message>"` — writes a crontab entry
2. At the scheduled time, system cron runs `cron.sh fire` which drops a `.jsonl` message into the agent's `.queue/inbox/`
3. The daemon's `collect_and_wait` sees the file and wakes on a normal msgbeat
4. Agent sees the message in their inbox: `[cron:weekly-review] Time for your weekly review...`
5. `cron.sh list` and `cron.sh remove` manage entries via crontab tagging (`fagents-cron:<handle>`)

## Verify

```bash
# Check skill is installed for an agent
ls $(eval echo "~$USER")/.claude/skills/cron/SKILL.md

# Check the path was substituted (should show actual path, not placeholder)
grep -c '__AUTONOMY_DIR__' $(eval echo "~$USER")/.claude/skills/cron/SKILL.md
# Expected: 0

# Test cron.sh works (as an agent user)
sudo -u "$USER" bash -c "PROJECT_DIR=~/workspace/$USER bash $AUTONOMY_DIR/cron.sh list"
# Expected: "No recurring tasks."
```

## Cleanup

To remove:
```bash
for USER in $AGENT_USERS; do
    sudo rm -rf "$(eval echo "~$USER")/.claude/skills/cron"
    # Remove any cron entries the agent created
    sudo -u "$USER" crontab -l 2>/dev/null | grep -v 'fagents-cron:' | sudo -u "$USER" crontab -
done
```
