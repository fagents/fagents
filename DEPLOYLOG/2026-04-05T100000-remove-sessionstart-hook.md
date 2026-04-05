# Remove SessionStart Hook — Deploy to Existing Installation

**Date:** 2026-04-05
**Repos changed:** fagents-autonomy, fagents
**Criticality:** LOW — informational hook removed, no operational impact if skipped

## What changed

The `SessionStart` hook (`startup-notice.sh`) has been removed. It was a meta-hook that listed active hooks and awareness scripts — purely informational, no effect on agent behavior. The daemon already logs its config at startup.

The script is replaced with a no-op stub (`exit 0`) so installs that pull autonomy before cleaning settings.json won't hit a missing file error.

This is the first step in eliminating Claude-specific hooks for multi-backend support.

## Steps

### 1. Pull repos

```bash
cd ~/workspace/fagents-autonomy && git pull
cd ~/workspace/fagents && git pull
```

Both repos changed: autonomy (hook removed), fagents (installer template updated — prevents SessionStart from being added to future agents).

### 2. Remove SessionStart from agent settings

For each agent:

```bash
cd ~/workspace/<agent>
python3 -c "
import json
f = '.claude/settings.json'
d = json.load(open(f))
hooks = d.get('hooks', {})
if 'SessionStart' in hooks:
    del hooks['SessionStart']
    json.dump(d, open(f, 'w'), indent=2)
    print('Removed SessionStart hook')
else:
    print('SessionStart hook not present — nothing to do')
"
```

### 3. Restart daemon

No restart strictly needed (the hook is now a no-op stub even if still in settings). But to pick up the clean state:

```bash
# Kill daemon PID — systemd/launchd auto-restarts it
sudo -u "$AGENT_USER" bash -c "kill \$(cat ~/workspace/\$USER/.autonomy/daemon.pid)"
```

## Doctor

Verify settings.json has no SessionStart:

```bash
python3 -c "
import json
d = json.load(open('.claude/settings.json'))
hooks = list(d.get('hooks', {}).keys())
print(f'Active hooks: {hooks}')
assert 'SessionStart' not in hooks, 'SessionStart still present!'
print('OK')
"
```
