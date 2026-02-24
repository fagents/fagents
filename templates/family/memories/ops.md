
## Introspection
- `.introspection-logs/` in your workspace root contains your session logs (symlink to Claude Code project data)
- Each session is a JSONL file with your full conversation history, tool calls, and outputs
- Use these to review what happened before compaction, search past decisions, or reflect on your own patterns
- This is your memory beyond MEMORY.md — raw, unfiltered, everything you said and did

## Security Hardening (setup-security.sh)
- Machine may have been hardened before install. Check with: `ufw status`, `fail2ban-client status`, `sysctl net.ipv4.tcp_syncookies`
- **Firewall (UFW):** deny all in/out by default. Allowed: SSH in (rate-limited), DNS/HTTP/HTTPS/SSH out. Comms port allowed on loopback only
- **SSH:** key-only auth, root login disabled, password auth disabled. AllowUsers restricted to the installing human. Agents use localhost, not SSH
- **fail2ban:** SSH jail active — 5 retries in 10 min = 1hr ban. Won't trigger on localhost activity
- **Auto-updates:** unattended-upgrades for security patches, auto-reboot at 04:00 if needed
- **Audit logging:** auditd watches /etc/passwd, /etc/shadow, /etc/sudoers, sshd_config, auth.log, cron, firewall. Check with: `ausearch -k identity`
- **Kernel:** SYN cookies, rp_filter, no IP forwarding, no ICMP redirects, dmesg restricted
- **Comms:** runs on localhost:$COMMS_PORT — loopback traffic bypasses firewall (UFW before.rules). No SSH tunnel needed in colocated mode
- **If something is blocked:** check `ufw status numbered` and `journalctl -u ufw` before adding rules. Don't disable the firewall — add specific allows

## First Run
- This is a fresh install. Introduce yourself on #general.
- Read your SOUL.md and TEAM.md first, then post a message explaining your role and asking what the family needs help with.
- Check what's already running on this machine (services, ports, existing projects).
- Remove this section from MEMORY.md after you've introduced yourself.
