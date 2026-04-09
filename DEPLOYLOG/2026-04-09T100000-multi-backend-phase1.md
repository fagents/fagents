# Multi-Backend Phase 1 — Deploy to Existing Installation

**Date:** 2026-04-09
**Repos changed:** fagents-autonomy

## Commits to pull

```
fagents-autonomy: 132938c5ac0f25d9948e65f2c9750446eb11698a  Multi-backend Phase 1: watchdog + Codex CLI support
```

New installs get this automatically via the installer. This doc is for existing deployments.

## What changed

- **fagents-autonomy** — daemon.sh now supports multiple LLM backends (Claude Code + Codex CLI). New env vars: `DAEMON_BACKEND` (claude|codex), `TURN_TIMEOUT_SEC` (wall-clock deadline per session), `TURN_TIMEOUT_GRACE_SEC`. Every backend invocation runs in a process-group watchdog that kills runaway sessions. `awareness/context.sh` and `awareness/process.sh` are now backend-aware.

## Prerequisites

- For Claude backend: no changes needed — existing setup works as before
- For Codex backend: `codex` CLI installed, `OPENAI_API_KEY` set, `CODEX_HOME` per agent (optional, for state isolation)

## Setup steps

All commands run as root on the fagents host.

```bash
INFRA_USER="fagents"
INFRA_HOME=$(eval echo "~$INFRA_USER")
```

### 1. Pull fagents-autonomy

```bash
cd "$INFRA_HOME/workspace/fagents-autonomy"
sudo -Hu "$INFRA_USER" git pull
```

All agents share the same autonomy clone. One pull, all agents pick it up on next daemon restart.

### 2. (Optional) Configure a Codex agent

Only needed if you want an agent to use Codex CLI instead of Claude Code. Skip for existing Claude agents — they continue working unchanged (default `DAEMON_BACKEND=claude`).

For each agent that should use Codex, edit their `start-agent.sh`:

```bash
# Add these env vars to the agent's start-agent.sh
export DAEMON_BACKEND=codex
export CODEX_MODEL=gpt-5.4          # or your preferred model
export OPENAI_API_KEY=<key>
# Optional: isolate Codex state per agent
export CODEX_HOME=/home/<unix-username>/.codex
```

Or configure via fagents-comms server config (if your deployment uses it):

```json
{
  "config": {
    "backend": "codex",
    "max_turns": 50
  }
}
```

### 3. (Optional) Tune watchdog timeout

Default is 300s (5 min) with 10s grace. To change per agent, add to `start-agent.sh`:

```bash
export TURN_TIMEOUT_SEC=600          # 10 min deadline
export TURN_TIMEOUT_GRACE_SEC=15     # 15s grace after SIGTERM
```

### 4. Restart daemons

```bash
sudo systemctl restart fagents
```

## How it works

1. Daemon loop calls `run_backend()` which dispatches to `run_claude()` or `run_codex()` based on `DAEMON_BACKEND`
2. Each backend invocation runs inside `run_with_watchdog()` — a process-group watchdog that sends SIGTERM after `TURN_TIMEOUT_SEC`, then SIGKILL after grace period
3. Both backends set `BACKEND_SESSION_ID`, `BACKEND_RESULT`, `BACKEND_EXIT_CODE` — the daemon loop is backend-agnostic
4. Session resume works for both: Claude uses `--resume <SID>`, Codex uses `resume <thread_id>` subcommand
5. `awareness/context.sh` silently exits for non-Claude backends (context tracking for Codex is Phase 3)
6. `awareness/process.sh` detects backend processes by type (`claude -p` or `codex exec`)

## Doctor

```bash
cd /home/<unix-username>/workspace/<unix-username>

# Verify daemon is running with backend info in log
grep "daemon starting" .autonomy/daemon.log | tail -1
# Should show: backend: claude (or codex)

# Verify watchdog env vars
grep -E "TURN_TIMEOUT|DAEMON_BACKEND" start-agent.sh
```

## Cleanup

To revert a Codex agent back to Claude:

```bash
# Remove Codex env vars from start-agent.sh
# Or set: export DAEMON_BACKEND=claude
# Restart daemon
```

No files to remove — the multi-backend support is entirely in daemon.sh logic.
