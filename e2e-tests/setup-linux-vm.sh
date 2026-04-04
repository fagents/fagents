#!/bin/bash
# setup-linux-vm.sh — Create a Linux VM for E2E testing via Tart
#
# Tart runs Linux VMs on Apple Silicon using the Virtualization framework.
# This script creates a VM, installs prerequisites, and copies the fagents repo in.
#
# Commands:
#   bash setup-linux-vm.sh              Create VM and provision it
#   bash setup-linux-vm.sh --test       Run E2E test inside the VM
#   bash setup-linux-vm.sh --ssh        Interactive SSH into the VM
#   bash setup-linux-vm.sh --stop       Stop the VM
#   bash setup-linux-vm.sh --start      Start existing VM
#   bash setup-linux-vm.sh --destroy    Stop and delete the VM
#
# First run pulls ~1GB base image. Subsequent runs reuse it.

set -euo pipefail

VM_NAME="fagents-test-linux"
BASE_IMAGE="ghcr.io/cirruslabs/ubuntu:latest"
VM_USER="admin"
VM_PASS="admin"
VM_IP=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# ── Helpers ──
vm_ssh() {
    sshpass -p "$VM_PASS" ssh -q \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "$VM_USER@$VM_IP" "$@"
}

vm_rsync() {
    rsync -a --exclude='.git' \
        -e "sshpass -p $VM_PASS ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
        "$@"
}

vm_running() {
    tart list 2>/dev/null | grep -q "$VM_NAME.*running"
}

get_ip() {
    VM_IP=$(tart ip "$VM_NAME" 2>/dev/null) || true
}

wait_for_ssh() {
    echo "  Waiting for SSH..."
    for i in $(seq 1 60); do
        get_ip
        if [[ -n "$VM_IP" ]] && vm_ssh "true" 2>/dev/null; then
            echo "  SSH ready at $VM_IP"
            return 0
        fi
        sleep 3
    done
    echo "ERROR: SSH not available after 3 minutes" >&2
    return 1
}

# ── Ensure dependencies ──
ensure_deps() {
    if ! command -v tart &>/dev/null; then
        echo "Installing Tart..."
        brew install cirruslabs/cli/tart
    fi
    if ! command -v sshpass &>/dev/null; then
        echo "Installing sshpass..."
        brew install hudochenkov/sshpass/sshpass
    fi
}

# ── Create VM ──
cmd_create() {
    ensure_deps

    if tart list 2>/dev/null | grep -q "$VM_NAME"; then
        echo "VM '$VM_NAME' already exists"
        if ! vm_running; then
            cmd_start
        fi
        wait_for_ssh
        return
    fi

    echo "Cloning base image (first run downloads ~1GB)..."
    tart clone "$BASE_IMAGE" "$VM_NAME"
    echo "  Done"

    cmd_start
    wait_for_ssh
}

# ── Start VM ──
cmd_start() {
    if vm_running; then
        echo "VM already running"
        get_ip
        return
    fi
    echo "Starting VM..."
    tart run --no-graphics "$VM_NAME" &
    disown
    sleep 5
}

# ── Provision (install prereqs + copy repo) ──
cmd_provision() {
    echo ""
    echo "=== Provisioning VM ==="
    get_ip
    if [[ -z "$VM_IP" ]]; then
        echo "ERROR: VM not running. Run: bash $0" >&2
        exit 1
    fi

    # Install prereqs
    echo "  Installing prerequisites..."
    vm_rsync "$SCRIPT_DIR/setup-linux-vm-prereqs.sh" "$VM_USER@$VM_IP:/tmp/setup-linux-vm-prereqs.sh"
    vm_ssh "echo '$VM_PASS' | sudo -S bash /tmp/setup-linux-vm-prereqs.sh"

    # Copy fagents repo (rsync excludes .git, has deterministic trailing-slash semantics)
    echo ""
    echo "  Copying fagents repo..."
    vm_ssh "mkdir -p ~/fagents/fagents ~/fagents/e2e-tests"
    vm_rsync "$REPO_ROOT/" "$VM_USER@$VM_IP:~/fagents/fagents/"
    vm_rsync "$REPO_ROOT/e2e-tests/" "$VM_USER@$VM_IP:~/fagents/e2e-tests/"
    echo "  Done"

    echo ""
    echo "=== VM ready ==="
    echo "  SSH:  ssh $VM_USER@$VM_IP  (password: $VM_PASS)"
    echo "  Test: bash $0 --test"
}

# ── Run E2E test ──
cmd_test() {
    get_ip
    if [[ -z "$VM_IP" ]]; then
        echo "ERROR: VM not running. Run: bash $0" >&2
        exit 1
    fi

    # Re-sync repo before test (picks up changes)
    echo "Syncing repo..."
    vm_ssh "mkdir -p ~/fagents/fagents ~/fagents/e2e-tests"
    vm_rsync "$REPO_ROOT/" "$VM_USER@$VM_IP:~/fagents/fagents/"
    vm_rsync "$REPO_ROOT/e2e-tests/" "$VM_USER@$VM_IP:~/fagents/e2e-tests/"

    echo ""
    echo "Running E2E test..."
    vm_ssh "echo '$VM_PASS' | sudo -S bash ~/fagents/e2e-tests/test-install-linux.sh"
}

# ── SSH ──
cmd_ssh() {
    get_ip
    if [[ -z "$VM_IP" ]]; then
        echo "ERROR: VM not running" >&2
        exit 1
    fi
    echo "Connecting to $VM_IP (password: $VM_PASS)..."
    sshpass -p "$VM_PASS" ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "$VM_USER@$VM_IP"
}

# ── Stop ──
cmd_stop() {
    if vm_running; then
        echo "Stopping VM..."
        tart stop "$VM_NAME"
        echo "  Done"
    else
        echo "VM not running"
    fi
}

# ── Destroy ──
cmd_destroy() {
    cmd_stop 2>/dev/null || true
    if tart list 2>/dev/null | grep -q "$VM_NAME"; then
        echo "Deleting VM..."
        tart delete "$VM_NAME"
        echo "  Done"
    else
        echo "VM doesn't exist"
    fi
}

# ── Main ──
case "${1:-}" in
    --test)    cmd_test ;;
    --ssh)     cmd_ssh ;;
    --stop)    cmd_stop ;;
    --start)   ensure_deps; cmd_start; wait_for_ssh ;;
    --destroy) cmd_destroy ;;
    --help|-h)
        sed -n '2,/^$/p' "$0" | sed -E 's/^# ?//'
        exit 0
        ;;
    "")
        cmd_create
        cmd_provision
        ;;
    *)
        echo "Unknown command: $1" >&2
        echo "Run with --help for usage" >&2
        exit 1
        ;;
esac
