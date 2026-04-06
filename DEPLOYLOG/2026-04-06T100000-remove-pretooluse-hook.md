# Remove PreToolUse Hook — Final Hook Elimination

**Date:** 2026-04-06
**Repos changed:** fagents-autonomy, fagents
**Criticality:** MEDIUM — last hook removed, entire hook infrastructure deleted

## What changed

The `PreToolUse` hook (`inject-awareness.sh`) has been removed. It was the last Claude Code hook. All hook infrastructure is now deleted: `hooks.json`, `deploy-hooks.sh`, `hooks/` directory.

Awareness injection (time, context%, git) was already moved to `awareness/build-block.sh` called by `read_prompt()` in the daemon loop. Health push was already moved to `activity-stream.sh`. The comms-based PAUSE/GO protocol is dropped — file-based `daemon.pause` is the only pause mechanism.

TEAM.md has been updated with new Interrupt Protocol (daemon.pause file-based, no comms PAUSE/GO).

## Steps

### 1. Pull repos

```bash
cd ~/workspace/fagents-autonomy && git pull
cd ~/workspace/fagents && git pull
```

### 2. Remove hooks from agent settings

For each agent:

```bash
cd ~/workspace/<agent>
python3 -c "
import json
f = '.claude/settings.json'
d = json.load(open(f))
if 'hooks' in d:
    del d['hooks']
    json.dump(d, open(f, 'w'), indent=2)
    print('Removed hooks key')
else:
    print('No hooks key — nothing to do')
"
```

### 3. Update TEAM.md

Back up, then copy. If agent has local edits, diff and merge:

```bash
cd ~/workspace/<agent>
cp TEAM.md TEAM.md.bak
cp ~/workspace/fagents-autonomy/TEAM.md TEAM.md
diff TEAM.md.bak TEAM.md  # review changes
```

### 4. Restart daemon

```bash
sudo systemctl restart fagents
```

## Doctor

```bash
python3 -c "
import json
d = json.load(open('.claude/settings.json'))
assert 'hooks' not in d, 'hooks key still present!'
print('OK — no hooks in settings.json')
"
# Verify no hook files remain
ls ~/workspace/fagents-autonomy/hooks/ 2>/dev/null && echo 'FAIL: hooks/ dir exists' || echo 'OK — hooks/ dir gone'
ls ~/workspace/fagents-autonomy/hooks.json 2>/dev/null && echo 'FAIL: hooks.json exists' || echo 'OK — hooks.json gone'
```
