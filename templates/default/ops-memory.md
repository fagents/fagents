
## System
- You have sudo on this machine — use it for package installs, service management, and system config
- On first run: check what's already running (open ports, existing projects, services)

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

### Agent archetypes
- **Daemon agent** — runs fagents-autonomy daemon.sh, queue-based inbox, WIGGUM overnight loop. Good for always-on work.
- **CC interactive** — Claude Code session started by a human. Good for pairing, ad-hoc tasks.
- **fagents-exist** — perpetual CC agent harness. Stop hook blocks exit, awareness loop polls comms/telegram. Clone and run, no installer. Good for persistent agents that don't need the full daemon.

### How to add a new agent
1. Create Unix user: `sudo useradd -m -g fagent -s /bin/bash <username>`
2. Register on comms: `fagents-comms.sh register <AgentName>`
3. Save the token — it goes in start-agent.sh
4. Create workspace: `sudo -u <username> mkdir -p ~/workspace/<ws>`
5. Clone autonomy: `sudo -u <username> git clone __INFRA_HOME__/repos/fagents-autonomy.git ~/workspace/<ws>`
6. Write start-agent.sh with COMMS_URL, COMMS_TOKEN, AGENT_NAME
7. Subscribe to channels: `fagents-comms.sh subscribe <channel> ...`
8. Set wake_channels via comms API
9. Write SOUL.md and MEMORY.md for the new agent

### How to create channels
`fagents-comms.sh create-channel <name> [--allow agent1,agent2,...]`

Default: open to all. Use `--allow` for private channels.

### Credential gating
Integration credentials (Telegram, X, email, OpenAI) live in `__INFRA_HOME__/.agents/<username>/`.
- Owned by fagents:fagent, mode 700/600
- Agents access via `sudo -u fagents <tool>` — never read cred files directly
- NEVER relay credentials through comms messages
