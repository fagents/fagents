# Telegram Attachment Downloads — Deploy to Existing Installation

**Date:** 2026-03-18
**Repos changed:** fagents-cli, fagents-autonomy

New installs get this automatically. This doc is for existing deployments.

## What changed

- **fagents-cli** — `telegram.sh poll` now detects photo, document, video, audio, and sticker messages (not just text + voice). New `telegram.sh download <file-id>` command downloads attachments by file_id. Telegram skill SKILL.md updated.
- **fagents-autonomy** — `collect_telegram()` in daemon.sh handles attachment types. Inbox messages include the attachment type, filename, caption, and the exact download command.

## Steps

### 1. Pull repos

```bash
INFRA_USER="fagents"
INFRA_HOME=$(eval echo "~$INFRA_USER")

for repo in fagents-cli fagents-autonomy; do
    sudo git -C "$INFRA_HOME/repos/${repo}.git" fetch "https://github.com/fagents/${repo}.git" main:main
    sudo git -C "$INFRA_HOME/workspace/${repo}" pull
done
```

### 2. Update telegram skill for interactive agents

Interactive agents need the updated SKILL.md. For **each interactive agent** (agents with `.claude/skills/telegram/`):

```bash
CLI_DIR="$INFRA_HOME/workspace/fagents-cli"
FAGENT_GID=$(getent group fagent | cut -d: -f3)
AGENT_USERS=$(getent passwd | awk -F: -v gid="$FAGENT_GID" '$4==gid {print $1}')

for USER in $AGENT_USERS; do
    SKILL_DIR=$(eval echo "~$USER")/.claude/skills/telegram
    [ -d "$SKILL_DIR" ] || continue
    sudo cp "$CLI_DIR/telegram/SKILL.md" "$SKILL_DIR/SKILL.md"
    sudo chown -R "$USER:fagent" "$SKILL_DIR"
    echo "$USER: telegram skill updated"
done
```

### 3. Restart daemon agents

The `telegram.sh` CLI changes are immediate. But `collect_telegram()` in daemon.sh only loads on daemon restart:

```bash
sudo systemctl restart fagents
```

Interactive agents load the updated skill on next session (no restart needed).

## How it works

1. Human sends photo/document/video to Telegram bot
2. `telegram.sh poll` outputs `{type: "photo", file_id: "...", text: "caption"}` (etc.)
3. Daemon's `collect_telegram()` writes to inbox: `[photo — look at this] download: sudo -u fagents telegram.sh download AbCdEf`
4. Agent wakes, sees the download command in their inbox, runs it to get the file
5. `telegram.sh download` calls Telegram getFile API → downloads from CDN → outputs `{path, filename, size}`

Telegram Bot API limit: files up to 20MB.
