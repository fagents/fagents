# Interactive CC Agents — Deploy to Existing Installation

**Date:** 2026-03-14
**Repos changed:** fagents, fagents-cli

## What changed

- **fagents-cli** — added `fagents-comms.sh` (comms CLI), `fagents-comms/SKILL.md`, `fagents-chat/SKILL.md`
- **fagents** — `install-agent.sh` supports `AGENT_TYPE=interactive` (no daemon, installs skills). Copied to `team/` dir during install.

## Steps

### 1. Pull fagents-cli

```bash
INFRA_HOME="/home/fagents"
sudo git -C "$INFRA_HOME/repos/fagents-cli.git" fetch "https://github.com/fagents/fagents-cli.git" main:main
sudo git -C "$INFRA_HOME/workspace/fagents-cli" pull
```

### 2. Copy install-agent.sh to team dir

Download the latest `install-agent.sh` and place it in the team dir:

```bash
sudo curl -fsSL https://raw.githubusercontent.com/fagents/fagents/main/install-agent.sh \
    -o "$INFRA_HOME/team/install-agent.sh"
sudo chmod +x "$INFRA_HOME/team/install-agent.sh"
sudo chown fagents:fagent "$INFRA_HOME/team/install-agent.sh"
```

### 3. Create an interactive agent (optional, to verify)

```bash
sudo useradd -m -g fagent -s /bin/bash scout

sudo su - scout -c "
    export NONINTERACTIVE=1
    export AGENT_NAME='Scout'
    export WORKSPACE='scout'
    export GIT_HOST='local'
    export COMMS_URL='http://127.0.0.1:9754'
    export AUTONOMY_REPO='$INFRA_HOME/repos/fagents-autonomy.git'
    export AUTONOMY_DIR='$INFRA_HOME/workspace/fagents-autonomy'
    export AUTONOMY_SHARED=1
    export CLI_DIR='$INFRA_HOME/workspace/fagents-cli'
    export AGENT_TYPE='interactive'
    bash $INFRA_HOME/team/install-agent.sh
"
```

### Verify

```bash
# Skills installed
ls /home/scout/.claude/skills/fagents-comms/SKILL.md
ls /home/scout/.claude/skills/fagents-chat/SKILL.md

# No daemon
test ! -f /home/scout/workspace/scout/start-agent.sh && echo "ok: no daemon"

# Launch
sudo su - scout -c 'cd ~/workspace/scout && claude'
```
