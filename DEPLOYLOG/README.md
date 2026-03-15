# Pulling Updates

Routine update instructions for Ops agents. No downtime, no reinstall.

## Repos on this install

```
/home/fagents/repos/fagents-comms.git       → /home/fagents/workspace/fagents-comms
/home/fagents/repos/fagents-autonomy.git    → /home/fagents/workspace/fagents-autonomy
/home/fagents/repos/fagents-cli.git         → /home/fagents/workspace/fagents-cli
/home/fagents/repos/fagents-mcp.git         → /home/fagents/workspace/fagents-mcp  (if email is configured)
```

Bare repos have no origin remote (security). Fetch directly from GitHub.

## Check what's behind

```bash
INFRA_HOME="/home/fagents"

for repo in fagents-comms fagents-autonomy fagents-cli fagents-mcp; do
    github_head=$(git ls-remote "https://github.com/fagents/${repo}.git" HEAD 2>/dev/null | cut -f1)
    local_head=$(git -C "$INFRA_HOME/repos/${repo}.git" rev-parse HEAD 2>/dev/null)
    if [[ "$github_head" == "$local_head" ]]; then
        echo "$repo: up to date"
    else
        echo "$repo: BEHIND (local ${local_head:0:7} → remote ${github_head:0:7})"
    fi
done
```

## Pull a repo

```bash
REPO="fagents-cli"  # change to whichever repo is behind

# 1. Fetch into bare repo
sudo git -C "$INFRA_HOME/repos/${REPO}.git" fetch "https://github.com/fagents/${REPO}.git" main:main

# 2. Pull into workspace
sudo git -C "$INFRA_HOME/workspace/${REPO}" pull
```

Repos are owned by the `fagents` user — sudo is required.

## After pulling

- **fagents-comms**: restart comms (`sudo /home/fagents/team/stop-comms.sh && sudo /home/fagents/team/start-comms.sh`)
- **fagents-autonomy**: agents pick up changes on next daemon restart (no action needed)
- **fagents-cli**: immediate (CLI tools are called directly, no daemon to restart)
- **fagents-mcp**: rebuild + restart (`sudo -u fagents bash -c 'cd ~/workspace/fagents-mcp && npm run build' && sudo systemctl restart fagents-mcp`)

## Feature-specific deploys

Files named `YYYY-MM-DDTHHMMSS-<feature>.md` in this directory have step-by-step instructions for deploying specific features that need more than a pull (new credentials, sudoers rules, etc).
