# E2E Install Tests

Automated full-cycle installer tests for fagents. Runs the real installer, verifies everything, cleans up.

## Linux

Runs on a remote server via SSH.

```bash
bash test-install.sh
```

**Requirements:** SSH access to a test host with sudo, Ubuntu 24.04+.

| Var | Default | Description |
|-----|---------|-------------|
| `TEST_HOST` | (required) | SSH target (e.g. `user@hostname`) |
| `COMMS_PORT` | `19754` | Port for test comms server |
| `TEMPLATE` | `business` | Installer template |
| `HUMAN_NAME` | `Tester` | Human name to register |

## macOS

Runs in a local macOS VM via [Tart](https://tart.run) (Apple Silicon only).

```bash
# First run: creates VM, installs prereqs, copies repo (~15GB download)
bash setup-test-vm.sh

# Run tests (re-syncs repo, so picks up local changes)
bash setup-test-vm.sh --test

# Other commands
bash setup-test-vm.sh --ssh        # shell into the VM
bash setup-test-vm.sh --stop       # shut down VM (keeps disk)
bash setup-test-vm.sh --start      # boot existing VM
bash setup-test-vm.sh --destroy    # delete VM + disk
```

The VM persists in `~/.tart/vms/fagents-test/` (~20GB). First run is slow; subsequent `--test` runs reuse the existing VM.

## What they test

1. **Cleanup** — remove any previous install artifacts
2. **Install** — non-interactive installer with business template
3. **Verify** — users, groups, repos, comms API, workspaces, secret isolation, telegram creds, team scripts
4. **Cleanup** — leave the machine clean
5. **Verify cleanup** — everything removed

Exit 0 if all pass, exit 1 if any fail. TAP-style output.
