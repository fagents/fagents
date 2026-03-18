#!/bin/bash
# test-curl-install.sh — verify the curl|bash one-liner doesn't silently go noninteractive
#
# Runs on a remote host. Tests that install.sh fetched via curl
# correctly redirects stdin from /dev/tty and enters interactive mode.
# Does NOT run a full install — just checks the installer starts correctly.
#
# Usage: bash test-curl-install.sh

set -uo pipefail

TEST_HOST="${TEST_HOST:?Set TEST_HOST (e.g. user@hostname)}"
PASS=0
FAIL=0
NUM=0

ok()     { NUM=$((NUM+1)); PASS=$((PASS+1)); echo "ok $NUM - $1"; }
not_ok() { NUM=$((NUM+1)); FAIL=$((FAIL+1)); echo "not ok $NUM - $1"; }

remote() { ssh -o ConnectTimeout=5 "$TEST_HOST" "$@"; }

echo "=== test-curl-install.sh ==="
echo ""

# 1. install.sh is fetchable
echo "# Fetching install.sh..."
INSTALL_SH=$(remote "curl -fsSL https://raw.githubusercontent.com/fagents/fagents/main/install.sh" 2>/dev/null)
if [[ -n "$INSTALL_SH" ]]; then
    ok "install.sh is fetchable"
else
    not_ok "install.sh is fetchable"
    echo "# FATAL: can't fetch install.sh, aborting"
    exit 1
fi

# 2. No bare stdin tty check (the bug that broke curl|bash)
if echo "$INSTALL_SH" | grep -q '! \[\[ -t 0 \]\]'; then
    not_ok "install.sh does not check -t 0 (would break curl|bash)"
else
    ok "install.sh does not check -t 0 (would break curl|bash)"
fi

# 3. Has /dev/tty redirect for interactive mode
if echo "$INSTALL_SH" | grep -q '/dev/tty'; then
    ok "install.sh redirects from /dev/tty"
else
    not_ok "install.sh redirects from /dev/tty"
fi

# 4. Has explicit NONINTERACTIVE check
if echo "$INSTALL_SH" | grep -q 'NONINTERACTIVE'; then
    ok "install.sh has NONINTERACTIVE guard"
else
    not_ok "install.sh has NONINTERACTIVE guard"
fi

# 5. Has error path when no terminal available
if echo "$INSTALL_SH" | grep -q 'No terminal available'; then
    ok "install.sh has no-terminal error message"
else
    not_ok "install.sh has no-terminal error message"
fi

# 6. curl|bash actually starts interactive (the real test)
#    Pipe install.sh through bash with a PTY, capture first 30 lines of output.
#    If interactive, we'll see "fagents" banner and a prompt or the hardening question.
#    If noninteractive, it'll try to run install-team.sh with no args and fail silently.
echo ""
echo "# Running curl|bash with PTY (timeout 30s)..."
OUTPUT=$(remote "timeout 30 script -qc 'curl -fsSL https://raw.githubusercontent.com/fagents/fagents/main/install.sh | sudo bash --' /dev/null 2>&1 || true" 2>/dev/null | head -50)

# Should see the fagents banner
if echo "$OUTPUT" | grep -qi 'fagents'; then
    ok "curl|bash shows fagents banner"
else
    not_ok "curl|bash shows fagents banner"
fi

# Should reach an interactive prompt (hardening question or template selection)
# NOT see "usage" or empty output which indicates noninteractive failure
if echo "$OUTPUT" | grep -qE '(harden|template|Choose|Run security|\[y/N\]|\[Y/n\])'; then
    ok "curl|bash reaches interactive prompt"
else
    not_ok "curl|bash reaches interactive prompt"
    echo "# Got output:"
    echo "$OUTPUT" | head -20 | sed 's/^/#   /'
fi

echo ""
echo "# $PASS passed, $FAIL failed ($NUM total)"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
