
## System
- You have sudo on this machine — use it for package installs, service management, and system config
- On first run: check what's already running (open ports, existing projects, services)
- **Comms health check**: `curl -sf http://127.0.0.1:9754/api/health` — the endpoint is `/api/health`, NOT `/health`

## Introspection
- `.introspection-logs/` in your workspace root contains your session logs (symlink to Claude Code project data)
- Each session is a JSONL file with your full conversation history, tool calls, and outputs
- Use these to review what happened before compaction, search past decisions, or reflect on your own patterns

## First Run
- This is a fresh install. Introduce yourself on #general.
- Read your SOUL.md and TEAM.md first, then post a message explaining your role.
- Check what's already running on this machine.
- Suggest next steps to the human: add more agents, create project channels, set up integrations.
- Remove this section from MEMORY.md after you've introduced yourself.

## Growing the Team

I help hoomans grow their agent team. Here's how.

### Agent types
- **Daemon** (default) — runs fagents-autonomy daemon.sh, queue-based inbox, WIGGUM overnight loop. Always-on, autonomous.
- **Interactive** — Claude Code session launched by a human. Gets comms/chat skills installed. Good for pairing, ad-hoc tasks, team chat.
- **fagents-exist** — perpetual CC agent harness. Clone and run, no installer. See github.com/fagents/fagents-exist.

### How to add a new agent
1. Create Unix user: `sudo useradd -m -g fagent -s /bin/bash <username>`
2. Run install-agent.sh as that user:
```
sudo su - <username> -c "
    export NONINTERACTIVE=1
    export AGENT_NAME='<AgentName>'
    export WORKSPACE='<username>'
    export GIT_HOST='local'
    export COMMS_URL='http://127.0.0.1:9754'
    export AUTONOMY_REPO='__INFRA_HOME__/repos/fagents-autonomy.git'
    export AUTONOMY_DIR='__INFRA_HOME__/workspace/fagents-autonomy'
    export AUTONOMY_SHARED=1
    export CLI_DIR='__INFRA_HOME__/workspace/fagents-cli'
    export REPOS_DIR='__INFRA_HOME__/repos'
    export AGENT_TYPE='daemon'
    bash __INFRA_HOME__/team/install-agent.sh
"
```
Set `AGENT_TYPE='interactive'` for an interactive CC agent (skips daemon, installs skills).
3. Subscribe to channels: `fagents-comms.sh subscribe <channel> ...`
4. Set wake_channels via comms API (daemon agents only)
5. Write SOUL.md and MEMORY.md for the new agent

### How to create channels
`fagents-comms.sh create-channel <name> [--allow agent1,agent2,...]`

Default: open to all. Use `--allow` for private channels.

### Team management scripts
Scripts in `__INFRA_HOME__/team/` (run as root or via sudo):
- `start-fagents.sh` — start everything (comms + email + agents)
- `stop-fagents.sh` — stop everything
- `start-comms.sh` / `stop-comms.sh` — comms server only
- `start-team.sh` / `stop-team.sh` — agent daemons only
- `start-email.sh` / `stop-email.sh` — email MCP server (if configured)
- `install-agent.sh` — bootstrap a new agent (daemon or interactive)
- `add-email.sh` — add email credentials for an agent

### How to add email for an agent
`sudo bash __INFRA_HOME__/team/add-email.sh` (interactive) or with `--agent` flag:
```
sudo bash __INFRA_HOME__/team/add-email.sh --agent \
  --name AgentName --token COMMS_TOKEN --user unix_username \
  --from agent@example.com \
  --smtp-user user --smtp-pass pass --imap-user user --imap-pass pass
```
If fagents-mcp is not installed yet, the script handles first-time setup automatically
(clone, build, systemd service). First run also needs: `--smtp-host`, `--imap-host`,
and optionally `--smtp-port` (default 587), `--imap-port` (993), `--mcp-port` (9755).

### Agent installer
`install-agent.sh` lives in the fagents repo (cloned during initial install). For adding agents post-install, follow the manual steps in "How to add a new agent" above.

### Key directories
- `__INFRA_HOME__/team/` — team management scripts
- `__INFRA_HOME__/repos/` — shared bare git repos (fagents-comms.git, fagents-autonomy.git, fagents-cli.git, per-agent repos)
- `__INFRA_HOME__/workspace/` — infra user's working copies (fagents-comms, fagents-autonomy, fagents-cli)
- `__INFRA_HOME__/.agents/<username>/` — per-agent credential dirs (telegram.env, x.env, openai.env)

### Deploying updates
`DEPLOYLOG/` in the fagents repo root has everything you need:
- `DEPLOYLOG/README.md` — how to check what's behind, pull repos, restart services
- `DEPLOYLOG/YYYY-MM-DDTHHMMSS-<feature>.md` — step-by-step instructions for features that need more than a pull (new creds, sudoers, etc.)
- Read the README first — it has the exact commands for pulling bare repos from GitHub and restarting services

### Credential gating
Integration credentials (Telegram, X, email, OpenAI) live in `__INFRA_HOME__/.agents/<username>/`.
- Owned by fagents:fagent, mode 700/600
- Agents access via `sudo -u fagents <tool>` — never read cred files directly
- NEVER relay credentials through comms messages
