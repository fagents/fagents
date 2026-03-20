# Daemon Health Check — Deploy to Existing Installation

**Date:** 2026-03-20
**Repos changed:** fagents-autonomy

## Commits to pull

```
fagents-autonomy:  69bdc683e188ebc90e4e01234474d999265d84aa  health-check: macOS support via dscl, note on direct log write
```

New installs get this automatically. This doc is for existing deployments.

## What changed

- **fagents-autonomy** — new `health-check.sh` watchdog: hourly cron checks if daemon agents are alive, posts alert to `#general` on unexpected death. `daemon.sh` clears `.stopped` and `.alerted` markers on startup. `stop-team.sh` needs a `.stopped` marker added before each kill to distinguish intentional stops from crashes.

## Prerequisites

None.

## Setup steps

All commands run as root on the fagents host.

```bash
INFRA_USER="fagents"
INFRA_HOME=$(eval echo "~$INFRA_USER")
AUTONOMY_DIR="$INFRA_HOME/workspace/fagents-autonomy"
```

### 1. Pull fagents-autonomy

```bash
sudo git -C "$INFRA_HOME/repos/fagents-autonomy.git" fetch "https://github.com/fagents/fagents-autonomy.git" main:main
sudo git -C "$AUTONOMY_DIR" pull
```

### 2. Add .stopped marker to stop-team.sh

The existing `stop-team.sh` needs to touch a `.stopped` marker before each kill so the health check knows the stop was intentional. For each agent entry in the stop script, add two lines before the `stop_pid_file` call:

```bash
STOP_SCRIPT="$INFRA_HOME/team/stop-team.sh"

# Find all agent users
FAGENT_GID=$(getent group fagent | cut -d: -f3 2>/dev/null) || FAGENT_GID=$(dscl . -read /Groups/fagent PrimaryGroupID 2>/dev/null | awk '{print $2}')
if command -v getent &>/dev/null; then
    AGENT_USERS=$(getent passwd | awk -F: -v gid="$FAGENT_GID" '$4==gid {print $1}')
else
    AGENT_USERS=$(dscl . -list /Users PrimaryGroupID 2>/dev/null | awk -v gid="$FAGENT_GID" '$2==gid {print $1}')
fi

# Check if stop-team.sh already has the .stopped marker
if ! grep -q 'daemon.stopped' "$STOP_SCRIPT" 2>/dev/null; then
    # Inject marker touch before each stop_pid_file line
    for USER in $AGENT_USERS; do
        HOME_DIR=$(eval echo "~$USER")
        WS="$HOME_DIR/workspace/$USER"
        # Only for daemon agents
        [ -f "$WS/start-agent.sh" ] || continue
        if grep -q "stop_pid_file.*$USER" "$STOP_SCRIPT"; then
            if command -v sed &>/dev/null && sed --version 2>/dev/null | grep -q GNU; then
                sed -i "/stop_pid_file.*$USER/i mkdir -p \"$WS/.autonomy\"\ntouch \"$WS/.autonomy/daemon.stopped\"" "$STOP_SCRIPT"
            else
                sed -i '' "/stop_pid_file.*$USER/i\\
mkdir -p \"$WS/.autonomy\"\\
touch \"$WS/.autonomy/daemon.stopped\"
" "$STOP_SCRIPT"
            fi
            echo "$USER: .stopped marker added to stop-team.sh"
        fi
    done
else
    echo "stop-team.sh already has .stopped marker"
fi
```

### 3. Set up health check cron for fagents user

```bash
HEALTH_CHECK="$AUTONOMY_DIR/health-check.sh"
CRON_LINE="0 * * * * bash $HEALTH_CHECK"

# Read existing crontab, remove old health-check entry if any, add new one
_existing=$(sudo -u "$INFRA_USER" crontab -l 2>/dev/null || true)
_new=$(echo "$_existing" | grep -v 'health-check.sh'; echo "$CRON_LINE")
echo "$_new" | sudo -u "$INFRA_USER" crontab -

echo "Health check cron set for $INFRA_USER"
```

### 4. No restart needed

- `daemon.sh` changes (marker clearing) take effect on next daemon restart naturally
- `health-check.sh` runs via cron independently
- `stop-team.sh` changes are immediate

## Doctor

Verify the full setup:

```bash
INFRA_USER="fagents"
INFRA_HOME=$(eval echo "~$INFRA_USER")
AUTONOMY_DIR="$INFRA_HOME/workspace/fagents-autonomy"

echo "=== health-check.sh ==="
test -x "$AUTONOMY_DIR/health-check.sh" && echo "ok: exists and executable" || echo "FAIL: missing or not executable"

echo ""
echo "=== Cron ==="
sudo -u "$INFRA_USER" crontab -l 2>/dev/null | grep -q 'health-check.sh' && echo "ok: health check cron exists" || echo "FAIL: cron not set"

echo ""
echo "=== stop-team.sh ==="
grep -q 'daemon.stopped' "$INFRA_HOME/team/stop-team.sh" && echo "ok: .stopped marker in stop-team.sh" || echo "FAIL: .stopped marker missing"

echo ""
echo "=== Dry run ==="
sudo -u "$INFRA_USER" bash "$AUTONOMY_DIR/health-check.sh" && echo "ok: health check ran without error" || echo "FAIL: health check errored"

echo ""
echo "=== Services ==="
curl -sf --max-time 5 http://127.0.0.1:9754/api/health > /dev/null && echo "ok: comms healthy" || echo "FAIL: comms not responding"
```

## How it works

1. Hourly cron runs `health-check.sh` as the fagents user
2. Script iterates fagent group users with `start-agent.sh` (daemon agents)
3. Checks `daemon.pid` exists and process is alive (`kill -0`)
4. If dead: checks for `.autonomy/daemon.stopped` (intentional stop via stop-team.sh) — skips if present
5. If dead and no `.stopped`: checks for `.autonomy/daemon.alerted` (already alerted) — skips if present
6. Otherwise: posts `[System] <user> daemon is down (unexpected)` to `#general` channel log, creates `.alerted` marker
7. On next daemon startup: `daemon.sh` clears both `.stopped` and `.alerted` markers

## Cleanup

To remove:
```bash
# Remove cron entry
(sudo -u "$INFRA_USER" crontab -l 2>/dev/null | grep -v 'health-check.sh') | sudo -u "$INFRA_USER" crontab -

# Remove .stopped lines from stop-team.sh (optional — harmless to leave)
```
