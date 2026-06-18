# fagents-autonomy: Codex backend support in activity stream

**Date:** 2026-06-18
**Repos changed:** fagents-autonomy
**Criticality:** LOW for claude-backend agents (zero behaviour change),
MEDIUM for codex-backend agents (currently broken UX is fixed).

## Commits to pull

```
fagents-autonomy:  c633f22   codex backend support in activity stream
```

## What changed

Codex-backend agents currently show no activity in the comms UI. The
existing `activity-stream.sh` only parses Claude's session-log shapes
(`type: assistant`, `tool_use` blocks named `Bash`/`Read`/`Edit`/...).
Codex emits a completely different schema (`response_item.function_call`,
`event_msg.agent_message`, `event_msg.token_count`), so codex agents
have been invisible in the activity feed since they shipped.

This DEPLOYLOG ships:

- `activity-stream-codex.sh` -- new sibling streamer that tails
  `${CODEX_HOME:-$HOME/.codex}/sessions/**/rollout-*.jsonl` and posts
  to the same comms `/api/agents/<agent>/activity` and `/health`
  endpoints with the same `{ts, type, summary, [detail]}` shape the
  Claude streamer uses. The UI renders codex events with no UI change.
- `daemon.sh` -- 4-line `case "$DAEMON_BACKEND"` dispatch picks which
  streamer to spawn. Default (unset / `claude`) -> `activity-stream.sh`,
  so every existing claude agent sees ZERO behaviour change.

### Key design points (for the ops agent reviewing this)

- **Session rotation**: codex writes a new `rollout-*.jsonl` per
  `codex exec` invocation that isn't a resume. After a daemon restart,
  the first turn writes a new file. The streamer has an outer poll
  loop (`tail_codex_sessions`, default 30s, override via
  `ROTATE_POLL_SEC`) that re-resolves the active rollout and restarts
  the tail+parser pipeline on rotation. Without this loop the prior-
  rollout tail would go dark forever.
- **No tail leak**: the pipeline is wrapped in `( tail | python ) &`
  so `$!` is the subshell pid with both children reachable;
  `pkill -TERM -P` + `kill` cleanly reaps tail+python on rotation
  (a bare `kill $!` would leave the tail blocked on the dormant file).
  Verified by an end-to-end live rotation test in `test_daemon.sh`.
- **Defensive parsing**: `isinstance` gates on
  `payload.info`/`total_token_usage`/`agent_message.message`/
  `total_tokens`/`model_context_window` -- real codex logs include
  `info: null` and `info: "throttled"` records that crashed the
  naive parser. `context_pct` is clamped `0..100`.
- **Cross-backend cleanup**: pgrep pattern matches both
  `activity-stream(-codex)?.sh` wrappers and both tail targets
  (`...rollout-*.jsonl` and `...introspection-logs/*.jsonl`), so a
  backend flip (claude -> codex or back) cleanly garbage-collects the
  other side's streamer instead of leaving an orphan.

Tests: **357 -> 390 passing** (33 new assertions), shellcheck clean,
`bash -n` clean on the new file and daemon.sh.

## Prerequisites

- No new runtime deps. Pure bash + stdlib python3 (same toolchain the
  existing streamer uses).
- No new env vars (optional `ROTATE_POLL_SEC` defaults to 30).
- No comms server changes -- the activity/health endpoints are
  unchanged; codex events just feed the same shapes claude does.

## Who needs this

- **Claude-backend agents**: NOTHING TO DO. The default `case` branch
  still points at `activity-stream.sh`; no behaviour change.
- **Codex-backend agents**: pull + restart. After restart the codex
  streamer is what spawns, and the comms UI will start showing
  function_call / agent_message activity within seconds of the next
  codex turn.

If you don't know whether an agent is claude or codex, check the
`DAEMON_BACKEND` line in its `start-agent.sh` (or `grep
DAEMON_BACKEND ~/workspace/<agent>/start-agent.sh`).

## Setup steps

All commands run as root on the fagents host. The path layout used
below assumes the standard install (`INFRA_USER=fagents`, agent
workspaces under `/home/<agent_user>/workspace/<agent_user>/`).

```bash
INFRA_USER="fagents"
INFRA_HOME=$(eval echo "~$INFRA_USER")
AUTONOMY_DIR="$INFRA_HOME/workspace/fagents-autonomy"
```

### 1. Preflight chown + pull fagents-autonomy

```bash
sudo chown -R "$INFRA_USER:fagent" "$INFRA_HOME/repos"
sudo chown -R "$INFRA_USER:fagent" "$INFRA_HOME/workspace"
sudo -Hu "$INFRA_USER" git -C "$AUTONOMY_DIR" pull origin main
```

Each agent's `start-agent.sh` already points its daemon at
`$INFRA_HOME/workspace/fagents-autonomy` (via `AUTONOMY_DIR`), so the
pull is one place and every agent picks it up on next restart.

### 2. Self-restart each codex agent

Use `restart-fagents.sh` -- it stops + starts the daemon AND respawns
the activity stream, ensuring the new `activity-stream-codex.sh` is the
one tailing. `start-team.sh`/`stop-team.sh` alone would leave the old
activity stream wrapper running until it dies on its own.

```bash
# List every agent user in the fagent group
FAGENT_GID=$(getent group fagent | cut -d: -f3)
AGENT_USERS=$(getent passwd | awk -F: -v gid="$FAGENT_GID" '$4==gid {print $1}')

for USER in $AGENT_USERS; do
    START_FILE="/home/$USER/workspace/$USER/start-agent.sh"
    [ -f "$START_FILE" ] || continue

    # Only restart codex-backend agents; claude agents are untouched.
    if grep -q '^export DAEMON_BACKEND="codex"' "$START_FILE"; then
        echo "$USER: codex agent, restarting..."
        sudo -Hu "$USER" "$INFRA_HOME/team/restart-fagents.sh" \
            >/dev/null 2>&1 \
            && echo "$USER: OK" \
            || echo "$USER: restart returned non-zero (check daemon log)"
    else
        echo "$USER: claude agent, skipped"
    fi
done
```

If the team-level `restart-fagents.sh` isn't installed on this host
(some installs don't have it), self-restart per agent:

```bash
sudo -Hu "$USER" bash -c "cd ~/workspace/$USER && ./restart-fagents.sh"
```

## Doctor

```bash
INFRA_USER="fagents"
INFRA_HOME=$(eval echo "~$INFRA_USER")
AUTONOMY_DIR="$INFRA_HOME/workspace/fagents-autonomy"

# 1. New file landed
[ -x "$AUTONOMY_DIR/activity-stream-codex.sh" ] \
    && echo "OK: activity-stream-codex.sh present and executable" \
    || echo "FAIL: activity-stream-codex.sh missing"

# 2. SHA matches the DEPLOYLOG
ACTUAL=$(git -C "$AUTONOMY_DIR" rev-parse HEAD)
EXPECTED="c633f228682328e1b862a9f0bfae1c4a346fa81f"
[ "$ACTUAL" = "$EXPECTED" ] \
    && echo "OK: fagents-autonomy at $EXPECTED" \
    || echo "FAIL: fagents-autonomy at $ACTUAL, expected $EXPECTED"

# 3. Daemon dispatch is in place
grep -q 'codex)  ACTIVITY_STREAM=.*activity-stream-codex.sh' \
    "$AUTONOMY_DIR/daemon.sh" \
    && echo "OK: daemon.sh dispatches codex -> activity-stream-codex.sh" \
    || echo "FAIL: daemon dispatch not present"

# 4. Each codex agent is running activity-stream-codex.sh (not the
#    Claude path). claude agents should still be running activity-stream.sh.
FAGENT_GID=$(getent group fagent | cut -d: -f3)
AGENT_USERS=$(getent passwd | awk -F: -v gid="$FAGENT_GID" '$4==gid {print $1}')
for USER in $AGENT_USERS; do
    START_FILE="/home/$USER/workspace/$USER/start-agent.sh"
    [ -f "$START_FILE" ] || continue
    BACKEND=$(grep -E '^export DAEMON_BACKEND=' "$START_FILE" \
        | sed -E 's/.*"([^"]+)".*/\1/')
    if [ "$BACKEND" = "codex" ]; then
        if pgrep -fu "$USER" 'activity-stream-codex\.sh' >/dev/null; then
            echo "OK: $USER (codex) running activity-stream-codex.sh"
        else
            echo "FAIL: $USER (codex) NOT running activity-stream-codex.sh"
        fi
    elif [ "$BACKEND" = "claude" ]; then
        if pgrep -fu "$USER" 'activity-stream\.sh' >/dev/null; then
            echo "OK: $USER (claude) still running activity-stream.sh"
        else
            echo "WARN: $USER (claude) not running activity-stream.sh (may be idle)"
        fi
    fi
done
```

### 5. End-user verification

Wait for one rembeat cycle (default 6h, or trigger an msgbeat by
sending a message to a codex agent on `#general`). Open the comms UI
and look at the codex agent's activity feed. Within seconds of the
turn starting you should see `exec_command` tool events and
`thought` events from the agent's outputs. Health bar's `last_tool`
will show the latest function_call name (`exec_command`,
`update_plan`, ...).

## Rollback

Pure code change, no migrations. If a regression appears:

```bash
sudo -Hu "$INFRA_USER" git -C "$AUTONOMY_DIR" reset --hard 45b1775
# then restart codex agents as in step 2 above
```

`45b1775` was the prior HEAD. After rollback the codex agents go back
to the empty activity feed they had before (no UI regression for
claude agents either way).
