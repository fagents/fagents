# Telegram Reply Context — Deploy to Existing Installation

**Date:** 2026-03-16
**Repos changed:** fagents-cli, fagents-autonomy

## What changed

When a Telegram message is a reply, the original message's sender and text are now included. `telegram.sh poll` outputs a `reply_to` field, and the daemon prepends it to the queue entry body.

## Steps

```bash
INFRA_HOME="/home/fagents"

# 1. Pull fagents-cli
sudo git -C "$INFRA_HOME/repos/fagents-cli.git" fetch "https://github.com/fagents/fagents-cli.git" main:main
sudo git -C "$INFRA_HOME/workspace/fagents-cli" pull

# 2. Pull fagents-autonomy
sudo git -C "$INFRA_HOME/repos/fagents-autonomy.git" fetch "https://github.com/fagents/fagents-autonomy.git" main:main
sudo git -C "$INFRA_HOME/workspace/fagents-autonomy" pull

# 3. Restart agents that use Telegram
sudo /home/fagents/team/stop-team.sh
sudo /home/fagents/team/start-team.sh
```

No new credentials or sudoers changes needed.
