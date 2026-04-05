# Remove Stop Hook — Deploy to Existing Installation

**Date:** 2026-04-05
**Repos changed:** fagents-autonomy
**Criticality:** LOW — hook was never installed by the installer, but deploy-hooks.sh may have pushed it

## What changed

The `Stop` hook (`session-stop.sh`) has been removed. It posted a "session ended" message to comms and a `stopped` health update when a Claude session ended.

The installer never wrote this hook to settings.json, but `deploy-hooks.sh` does a full dict replace from `hooks.json` — so if it was ever run on an agent, Stop may be in their settings. The script has been deleted, so a stale Stop entry would reference a missing file.

## Steps

### 1. Pull fagents-autonomy

```bash
cd ~/workspace/fagents-autonomy && git pull
```

### 2. Remove Stop from agent settings (if present)

For each agent:

```bash
cd ~/workspace/<agent>
python3 -c "
import json
f = '.claude/settings.json'
d = json.load(open(f))
hooks = d.get('hooks', {})
if 'Stop' in hooks:
    del hooks['Stop']
    json.dump(d, open(f, 'w'), indent=2)
    print('Removed Stop hook')
else:
    print('Stop hook not present — nothing to do')
"
```

### 3. No restart needed

The settings change takes effect on next session. No daemon restart required.

## Doctor

```bash
python3 -c "
import json
d = json.load(open('.claude/settings.json'))
hooks = list(d.get('hooks', {}).keys())
print(f'Active hooks: {hooks}')
assert 'Stop' not in hooks, 'Stop still present!'
assert 'SessionStart' not in hooks, 'SessionStart still present!'
print('OK')
"
```
