# Move UserPromptSubmit to Daemon — Deploy to Existing Installation

**Date:** 2026-04-05
**Repos changed:** fagents-autonomy, fagents
**Criticality:** MEDIUM — awareness injection moves from hook to daemon, requires restart

## What changed

The `UserPromptSubmit` hook (`inject-context.sh`) has been replaced by daemon-side prompt injection. Time, context%, compaction alerts, and git status are now prepended to the prompt by `read_prompt()` in daemon.sh via a new `awareness/build-block.sh` script.

The hook script has been deleted. Agents that still have `UserPromptSubmit` in settings.json will get a harmless "hook script not found" warning until cleaned up.

## Steps

**Order matters.** Remove the hook from settings BEFORE restarting the daemon. If reversed, agents temporarily get duplicate awareness (new daemon injection + stale hook).

### 1. Pull repos

```bash
cd ~/workspace/fagents-autonomy && git pull
cd ~/workspace/fagents && git pull
```

### 2. Remove UserPromptSubmit from agent settings

For each agent:

```bash
cd ~/workspace/<agent>
python3 -c "
import json
f = '.claude/settings.json'
d = json.load(open(f))
hooks = d.get('hooks', {})
if 'UserPromptSubmit' in hooks:
    del hooks['UserPromptSubmit']
    json.dump(d, open(f, 'w'), indent=2)
    print('Removed UserPromptSubmit hook')
else:
    print('UserPromptSubmit hook not present — nothing to do')
"
```

### 3. Restart daemon

Required — daemon.sh has new code in `read_prompt()`. Use your install's restart method:

- **imagine-emerge:** `sudo systemctl restart fagents`
- **other systemd installs:** `sudo systemctl restart fagents`
- **launchd (macOS):** agent auto-restarts on next wake

## Doctor

```bash
python3 -c "
import json
d = json.load(open('.claude/settings.json'))
hooks = list(d.get('hooks', {}).keys())
print(f'Active hooks: {hooks}')
assert 'UserPromptSubmit' not in hooks, 'UserPromptSubmit still present!'
print('OK — remaining hooks should be: PreToolUse, PostToolUse')
"
```
