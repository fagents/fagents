# Remove SessionStart Hook — Deploy to Existing Installation

**Date:** 2026-04-05
**Repos changed:** fagents-autonomy, fagents
**Criticality:** LOW — informational hook removed, no operational impact if skipped

## What changed

The `SessionStart` hook (`startup-notice.sh`) has been removed. It was a meta-hook that listed active hooks and awareness scripts — purely informational, no effect on agent behavior. The daemon already logs its config at startup.

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

### 3. Restart daemon (optional)

No restart strictly needed — Claude Code picks up settings.json changes on next session. But to pick up the clean state immediately, restart the agent daemon using whatever method your install uses. For example:

- **imagine-emerge:** `sudo systemctl restart fagents`
- **other systemd installs:** `sudo systemctl restart fagents`
- **launchd (macOS):** agent auto-restarts on next wake

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
