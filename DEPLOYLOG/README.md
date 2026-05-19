# Pulling Updates

Routine update instructions for Ops agents. No downtime, no reinstall.

## Repos on this install

```
/home/fagents/repos/fagents.git             → /home/fagents/workspace/fagents        (DEPLOYLOG tracking — only pull after deploying)
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

# 0. Preflight: normalize .git ownership. Idempotent; covers pre-existing
#    installs where prior raw `sudo git` ops left root-owned objects in
#    .git/objects/ -- those silently break future fagents-owned pulls.
sudo chown -R fagents:fagent "$INFRA_HOME/repos/${REPO}.git"
sudo chown -R fagents:fagent "$INFRA_HOME/workspace/${REPO}/.git"

# 1. Fetch into bare repo (run AS fagents so new objects are fagents-owned)
sudo -Hu fagents git -C "$INFRA_HOME/repos/${REPO}.git" \
    fetch "https://github.com/fagents/${REPO}.git" main:main

# 2. Pull into workspace (same reasoning)
sudo -Hu fagents git -C "$INFRA_HOME/workspace/${REPO}" pull
```

Repos are owned by the `fagents` user. Always run write-side git ops
(fetch / pull / clone) through `sudo -Hu fagents` so new objects are
created as `fagents:fagent`. Raw `sudo git` runs as root and creates
root-owned objects in `.git/objects/`, which then break future
fagents-owned pulls until chown'd back.

## After pulling

- **fagents-comms**: restart comms (`sudo /home/fagents/team/stop-comms.sh && sudo /home/fagents/team/start-comms.sh`)
- **fagents-autonomy**: agents pick up changes on next daemon restart (no action needed)
- **fagents-cli**: immediate (CLI tools are called directly, no daemon to restart)
- **fagents-mcp**: rebuild + restart (`sudo -u fagents bash -c 'cd ~/workspace/fagents-mcp && npm run build' && sudo systemctl restart fagents-mcp`)

## Feature-specific deploys

Files named `YYYY-MM-DDTHHMMSS-<feature>.md` in this directory have step-by-step instructions for deploying specific features that need more than a pull (new credentials, sudoers rules, etc).
