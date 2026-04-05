# Remove SessionStart Hook — Deploy to Existing Installation

**Date:** 2026-04-05
**Repos changed:** fagents-autonomy
**Criticality:** LOW — informational hook removed, no operational impact if skipped

## What changed

The `SessionStart` hook (`startup-notice.sh`) has been removed. It was a meta-hook that listed active hooks and awareness scripts — purely informational, no effect on agent behavior. The daemon already logs its config at startup.

This is the first step in eliminating Claude-specific hooks for multi-backend support.

## Steps

### 1. Pull fagents-autonomy

```bash
cd ~/workspace/fagents-autonomy && git pull
```

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

### 3. Restart agent daemon

```bash
sudo systemctl restart fagents-<agent>
```

Or if using launchd (macOS):
```bash
launchctl kickstart -k gui/$(id -u)/com.fagents.<agent>
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
