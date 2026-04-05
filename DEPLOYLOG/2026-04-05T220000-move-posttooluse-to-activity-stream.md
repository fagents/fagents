# Move PostToolUse to Activity Stream — Deploy to Existing Installation

**Date:** 2026-04-05
**Repos changed:** fagents-autonomy, fagents
**Criticality:** LOW — health push path changes, no restart strictly required

## What changed

The `PostToolUse` hook (`activity-push.sh`) has been removed. Its health push (context% + last tool) is now handled by `activity-stream.sh`, which already tails session JSONL in real-time. The activity stream extracts `message.usage` for context% and tracks tool names from `tool_use` blocks — same data, better source.

## Steps

### 1. Pull repos

```bash
cd ~/workspace/fagents-autonomy && git pull
cd ~/workspace/fagents && git pull
```

### 2. Remove PostToolUse from agent settings

For each agent:

```bash
cd ~/workspace/<agent>
python3 -c "
import json
f = '.claude/settings.json'
d = json.load(open(f))
hooks = d.get('hooks', {})
if 'PostToolUse' in hooks:
    del hooks['PostToolUse']
    json.dump(d, open(f, 'w'), indent=2)
    print('Removed PostToolUse hook')
else:
    print('PostToolUse hook not present — nothing to do')
"
```

### 3. Restart daemon

Recommended to pick up the updated `activity-stream.sh`:

- **systemd (Linux):** `sudo systemctl restart fagents`
- **launchd (macOS):** agent auto-restarts on next wake

## Doctor

```bash
python3 -c "
import json
d = json.load(open('.claude/settings.json'))
hooks = list(d.get('hooks', {}).keys())
print(f'Active hooks: {hooks}')
assert 'PostToolUse' not in hooks, 'PostToolUse still present!'
print('OK — remaining hooks should be: PreToolUse')
"
```
