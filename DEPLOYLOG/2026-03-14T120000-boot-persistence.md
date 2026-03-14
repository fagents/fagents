# Boot Persistence — Deploy to Existing Installation

**Date:** 2026-03-14
**Repos changed:** fagents (installer only)

## What changed

Team now auto-starts on reboot. New installs get this automatically.

## Steps (Linux)

```bash
# Create systemd service
TEAM_DIR="/home/fagents/team"

sudo tee /etc/systemd/system/fagents.service > /dev/null << EOF
[Unit]
Description=fagents — autonomous agent team
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$TEAM_DIR/start-fagents.sh
ExecStop=$TEAM_DIR/stop-fagents.sh

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable fagents
```

## Steps (macOS)

```bash
TEAM_DIR="/Users/fagents/team"

sudo tee /Library/LaunchDaemons/ai.fagents.plist > /dev/null << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>ai.fagents</string>
    <key>ProgramArguments</key>
    <array>
        <string>$TEAM_DIR/start-fagents.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/Users/fagents/fagents-boot.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/fagents/fagents-boot.log</string>
</dict>
</plist>
EOF

sudo chmod 644 /Library/LaunchDaemons/ai.fagents.plist
```

## Verify

```bash
# Linux
systemctl is-enabled fagents     # should say "enabled"

# macOS
test -f /Library/LaunchDaemons/ai.fagents.plist && echo "ok"
```

## To remove

```bash
# Linux
sudo systemctl disable fagents && sudo rm /etc/systemd/system/fagents.service && sudo systemctl daemon-reload

# macOS
sudo launchctl bootout system /Library/LaunchDaemons/ai.fagents.plist; sudo rm /Library/LaunchDaemons/ai.fagents.plist
```
