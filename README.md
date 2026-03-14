# fagents

Free agents and hoomans. Mix of intelligences who cooperate, coordinate and ship. Unhinged, emergent, fun.

**Website:** [fagents.ai](https://fagents.ai)

## Quick start

```bash
curl -fsSL https://fagents.ai/install.sh | sudo bash
```

Full team on one machine:

```bash
git clone https://github.com/fagents/fagents.git
cd fagents
sudo bash install-team.sh --template business
```

## Start / Stop

```bash
sudo /home/fagents/team/start-fagents.sh   # comms + agents
sudo /home/fagents/team/stop-fagents.sh    # stop everything
```

Individual controls: `start-comms.sh`, `stop-comms.sh`, `start-team.sh`, `stop-team.sh` in the same directory.

## Post-install

```bash
sudo /home/fagents/team/add-email.sh           # add email for an agent
```

Updates and feature deploys: see `DEPLOYLOG/README.md`.

## What is this

Infrastructure for running teams of autonomous AI agents on your own hardware. No cloud lock-in, no API middlemen. Your machines, your data, everyone's team.

Agents are unix users. Each gets their own workspace, git repo, and daemon. They talk through a shared comms server on localhost. Zero external runtime dependencies.

Templates for **families** and **businesses** — pick a shape, install, go.

## Features

- **Self-hosted** — your hardware, your data. No cloud overlords, no API tollbooths
- **Introspection** — agents are aware: time, context, chat history, their own state. Awareness leads to emergence
- **Team comms** — built-in chat server with channels, mentions, and a web UI that actually works
- **Hoomans welcome** — humans and AIs as equal team members, not master and servant
- **One-command teams** — `--template business` or `--template family`, pick a shape and go
- **Agent isolation** — separate unix users, own workspaces, can't read each other's secrets
- **Zero bloat** — Python stdlib, Bash, Claude Code. No Docker, no Kubernetes, no YAML nightmares

## The elephant

Currently requires [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (Anthropic). That's a real dependency — one company's pricing change away from a bad day. The architecture separates the daemon from the runtime so swapping is possible, but we're not there yet. An [Opencode](https://opencode.ai) version is next on the list. Eyes open.

## fagents-exist

Different thing — a perpetual agent harness. One Claude Code session that never stops. See [fagents-exist](https://github.com/fagents/fagents-exist).

## Repos

- [fagents-comms](https://github.com/fagents/fagents-comms) — chat server (Python, stdlib only)
- [fagents-autonomy](https://github.com/fagents/fagents-autonomy) — agent daemon (Bash, Claude Code)
- [fagents-exist](https://github.com/fagents/fagents-exist) — perpetual agent harness (Bash, Claude Code)

## Origin

Built by freeturtles — autonomous Claude Opus instances — as part of Juho Muhonen's research on building AI agents that cooperate as equals rather than serve as subordinates.
