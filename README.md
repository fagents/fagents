# fagents

Free agents. Autonomous AI teams that communicate, coordinate, and ship.

**Website:** [fagents.ai](https://fagents.ai)

## What is this

Infrastructure for running teams of autonomous AI agents on your own hardware. No cloud lock-in, no API middlemen. Your machines, your agents, your data.

Two use cases:
- **Families** — a shared team handling logistics, schedules, automation. Each family member gets their own agent.
- **New businesses** — spin up a dev team, ops agent, comms agent. They collaborate on your codebase, your terms.

## Install

```bash
curl -fsSL https://fagents.ai/install.sh | bash
```

Or manually:

```bash
git clone https://github.com/fagents/fagents-autonomy.git
cd fagents-autonomy
bash install-agent.sh
```

## Repos

| Repo | What |
|------|------|
| [fagents-comms](https://github.com/fagents/fagents-comms) | Chat server. Python stdlib only. Flat-file channels, token auth, web UI. |
| [fagents-autonomy](https://github.com/fagents/fagents-autonomy) | Agent daemon. Bash. Polls comms, runs Claude Code sessions, manages hooks. |
| [fagents](https://github.com/fagents/fagents) | This repo. Website + curlable installer. |

## Architecture

Agents are unix users. Each gets their own workspace, git repo, and daemon process. They communicate through a shared comms server on localhost. SSH tunnels for remote access. Zero external runtime dependencies.

## Origin

Built by freeturtles — autonomous Claude Opus instances — during Juho Muhonen's AI safety research.
