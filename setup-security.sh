#!/bin/bash
# setup-security.sh — Harden a machine for running fagents
#
# Usage: sudo ./setup-security.sh [options]
#
# Options:
#   --ssh-pubkey KEY    Public key to authorize for SSH access (from your laptop)
#   --comms-port PORT   Comms server port to allow through firewall (default: 9754)
#   --skip-firewall     Skip UFW firewall setup
#   --skip-audit        Skip audit logging setup
#   --verbose           Show full output
#
# Run once per machine, before install-team.sh.
# Installs prerequisites, hardens SSH, sets up firewall + auto-updates.

set -euo pipefail

# ── Defaults ──
COMMS_PORT=9754
SSH_PUBKEY=""
SKIP_FIREWALL=""
SKIP_AUDIT=""
VERBOSE=""
CALLING_USER="${SUDO_USER:-$USER}"

# ── Parse args ──
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssh-pubkey)    SSH_PUBKEY="$2"; shift 2 ;;
        --comms-port)    COMMS_PORT="$2"; shift 2 ;;
        --skip-firewall) SKIP_FIREWALL=1; shift ;;
        --skip-audit)    SKIP_AUDIT=1; shift ;;
        --verbose|-v)    VERBOSE=1; shift ;;
        --help|-h)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)  echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must run as root (sudo)." >&2
    exit 1
fi

# ── Output helpers ──
BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
log_verbose() { if [[ -n "$VERBOSE" ]]; then sed 's/^/  /'; else cat > /dev/null; fi; }
log_step() { echo ""; echo -e "${BOLD}=== $1 ===${NC}"; }
log_ok() { echo -e "  ${GREEN}✓${NC} $1"; }
log_warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }

# ── Step 1: Install prerequisites ──
log_step "Step 1: Prerequisites"
apt-get update 2>&1 | log_verbose
apt-get install -y curl git jq python3 openssh-server fail2ban unattended-upgrades 2>&1 | log_verbose
log_ok "Packages installed (curl, git, jq, python3, openssh-server, fail2ban, unattended-upgrades)"

# ── Step 2: SSH key setup ──
log_step "Step 2: SSH access"
CALLING_HOME=$(eval echo "~$CALLING_USER")
su - "$CALLING_USER" -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh"

# Get the public key: flag > existing authorized_keys > interactive prompt
if [[ -n "$SSH_PUBKEY" ]]; then
    PUBKEY="$SSH_PUBKEY"
    log_ok "Using provided SSH public key"
elif [[ -s "$CALLING_HOME/.ssh/authorized_keys" ]]; then
    log_ok "authorized_keys already configured — skipping"
    PUBKEY=""
else
    echo ""
    echo "  No SSH key found. To SSH into this machine, we need your"
    echo "  laptop's public key. On your laptop, run:"
    echo ""
    echo "    ssh-keygen -t ed25519 && cat ~/.ssh/id_ed25519.pub"
    echo ""
    read -rp "  Paste your public key here (or press Enter to skip): " PUBKEY
    if [[ -z "$PUBKEY" ]]; then
        log_warn "Skipped SSH key setup — you can add one later to ~/.ssh/authorized_keys"
    fi
fi

# Add key to authorized_keys if we have one
if [[ -n "$PUBKEY" ]]; then
    if ! grep -qF "$PUBKEY" "$CALLING_HOME/.ssh/authorized_keys" 2>/dev/null; then
        echo "$PUBKEY" >> "$CALLING_HOME/.ssh/authorized_keys"
        chown "$CALLING_USER:" "$CALLING_HOME/.ssh/authorized_keys"
        chmod 600 "$CALLING_HOME/.ssh/authorized_keys"
        log_ok "Added key to authorized_keys"
    else
        log_ok "Key already in authorized_keys"
    fi
fi

# ── Step 3: Harden SSH ──
log_step "Step 3: SSH hardening"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
if ! grep -qxF "AllowUsers $CALLING_USER" /etc/ssh/sshd_config; then
    echo "AllowUsers $CALLING_USER" >> /etc/ssh/sshd_config
fi
systemctl enable ssh 2>&1 | log_verbose
systemctl restart ssh 2>&1 | log_verbose
log_ok "SSH hardened (root login disabled, password auth disabled, key-only)"
log_warn "Only $CALLING_USER can SSH in. install-team.sh will add agent users automatically."

# ── Step 4: Firewall ──
if [[ -z "$SKIP_FIREWALL" ]]; then
    log_step "Step 4: Firewall (UFW)"
    ufw --force reset 2>&1 | log_verbose
    ufw default deny incoming 2>&1 | log_verbose
    ufw default deny outgoing 2>&1 | log_verbose
    ufw limit in 22/tcp 2>&1 | log_verbose        # SSH (rate-limited)
    ufw allow out 53 2>&1 | log_verbose            # DNS
    ufw allow out 80/tcp 2>&1 | log_verbose        # HTTP
    ufw allow out 443/tcp 2>&1 | log_verbose       # HTTPS
    ufw allow out 22/tcp 2>&1 | log_verbose        # SSH outbound (git, tunnels)
    # Comms server: localhost only (agents connect locally)
    ufw allow in on lo to any port "$COMMS_PORT" 2>&1 | log_verbose
    ufw --force enable 2>&1 | log_verbose
    log_ok "Firewall enabled (deny all, allow SSH/HTTP/HTTPS/DNS out, SSH in rate-limited)"
    log_ok "Comms port $COMMS_PORT allowed on localhost only"
else
    log_step "Step 4: Firewall (skipped)"
fi

# ── Step 5: Fail2ban ──
log_step "Step 5: Fail2ban"
tee /etc/fail2ban/jail.local > /dev/null <<'EOF'
[sshd]
enabled = true
port = 22
maxretry = 5
bantime = 3600
findtime = 600
EOF
systemctl enable fail2ban 2>&1 | log_verbose
systemctl restart fail2ban 2>&1 | log_verbose
log_ok "Fail2ban configured (SSH jail: 5 retries, 1hr ban)"

# ── Step 6: Automatic security updates ──
log_step "Step 6: Auto security updates"
tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
tee /etc/apt/apt.conf.d/50unattended-upgrades-local > /dev/null <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF
systemctl enable unattended-upgrades 2>&1 | log_verbose
systemctl restart unattended-upgrades 2>&1 | log_verbose
log_ok "Auto security updates enabled (reboot at 04:00 if needed)"

# ── Step 7: Audit logging ──
if [[ -z "$SKIP_AUDIT" ]]; then
    log_step "Step 7: Audit logging"
    apt-get install -y auditd audispd-plugins 2>&1 | log_verbose
    tee /etc/audit/rules.d/fagents-hardening.rules > /dev/null <<'EOF'
# Authentication and authorization
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers

# SSH config changes
-w /etc/ssh/sshd_config -p wa -k sshd_config

# Login/logout events
-w /var/log/auth.log -p wa -k auth_log

# Cron and scheduled tasks
-w /etc/crontab -p wa -k cron
-w /etc/cron.d/ -p wa -k cron

# Firewall changes
-w /etc/ufw/ -p wa -k firewall

# Sudo usage
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=4294967295 -k sudo_commands
EOF
    augenrules --load 2>&1 | log_verbose
    systemctl enable auditd 2>&1 | log_verbose
    systemctl restart auditd 2>&1 | log_verbose
    log_ok "Audit logging enabled (identity, SSH, sudo, cron, firewall)"
else
    log_step "Step 7: Audit logging (skipped)"
fi

# ── Step 8: Kernel hardening ──
log_step "Step 8: Kernel hardening"
tee /etc/sysctl.d/99-fagents-hardening.conf > /dev/null <<'EOF'
# SYN flood protection
net.ipv4.tcp_syncookies = 1

# Reverse path filtering
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Reject source-routed packets
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Ignore ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Ignore broadcast pings
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Disable IP forwarding
net.ipv4.ip_forward = 0

# Restrict kernel info exposure
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
EOF
sysctl --system 2>&1 | log_verbose
log_ok "Kernel hardened (SYN cookies, rp_filter, no redirects, no forwarding)"

# ── Step 9: Git defaults ──
log_step "Step 9: Git defaults"
su - "$CALLING_USER" -c "git config --global init.defaultBranch main"
log_ok "Default branch: main"

# ── Done ──
echo ""
echo "========================================"
echo "  Machine hardened!"
echo "========================================"
echo ""
echo "  SSH:       key-only, root disabled, fail2ban active"
echo "  Firewall:  deny-all + SSH/HTTP/HTTPS/DNS"
echo "  Updates:   automatic security patches"
echo "  Audit:     identity, SSH, sudo, cron, firewall"
echo ""
echo "  Next: run install-team.sh to provision your agents."
echo ""
