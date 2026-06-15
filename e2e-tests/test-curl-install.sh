#!/bin/bash
# test-curl-install.sh -- verify the fetched install.sh is env/blob-only.
#
# Runs on a remote host. install.sh no longer has an interactive mode: a bare
# curl|bash must print the fagents.ai/install/ signpost and exit non-zero (no
# /dev/tty, no silent noninteractive run). Fetches install.sh from GitHub main,
# so run this AFTER pushing.
#
# Usage: TEST_HOST=user@host bash test-curl-install.sh

set -uo pipefail

TEST_HOST="${TEST_HOST:?Set TEST_HOST (e.g. user@hostname)}"
RAW="https://raw.githubusercontent.com/fagents/fagents/main/install.sh"
PASS=0; FAIL=0; NUM=0

ok()     { NUM=$((NUM+1)); PASS=$((PASS+1)); echo "ok $NUM - $1"; }
not_ok() { NUM=$((NUM+1)); FAIL=$((FAIL+1)); echo "not ok $NUM - $1"; }
remote() { ssh -o ConnectTimeout=5 "$TEST_HOST" "$@"; }
has()    { echo "$INSTALL_SH" | grep -q "$1"; }

echo "=== test-curl-install.sh ==="
echo ""

# 1. install.sh is fetchable
echo "# Fetching install.sh..."
INSTALL_SH=$(remote "curl -fsSL $RAW" 2>/dev/null)
if [[ -n "$INSTALL_SH" ]]; then
    ok "install.sh is fetchable"
else
    not_ok "install.sh is fetchable"
    echo "# FATAL: can't fetch install.sh, aborting"
    exit 1
fi

# 2. Interactive mode is gone (no /dev/tty redirect)
if has '/dev/tty'; then
    not_ok "install.sh no longer redirects from /dev/tty"
else
    ok "install.sh no longer redirects from /dev/tty"
fi

# 3. Carries the config-blob decode shim
if has 'ALLOWED_STATIC'; then ok "install.sh has the key allowlist"; else not_ok "install.sh has the key allowlist"; fi
if has 'base64 -d';     then ok "install.sh decodes a base64 blob"; else not_ok "install.sh decodes a base64 blob"; fi

# 4. Decodes via allowlist, NOT eval (env-injection safe). Strip comments first
#    so the explanatory "never eval'd" comments don't trip a literal grep.
if echo "$INSTALL_SH" | sed 's/#.*//' | grep -qw 'eval'; then
    not_ok "install.sh shim does not use eval"
else
    ok "install.sh shim does not use eval"
fi

# 5. Signposts to fagents.ai/install/
if has 'fagents.ai/install/'; then ok "install.sh signposts to fagents.ai/install/"; else not_ok "install.sh signposts to fagents.ai/install/"; fi

# 6. Still honors NONINTERACTIVE (automation path)
if has 'NONINTERACTIVE'; then ok "install.sh keeps a NONINTERACTIVE path"; else not_ok "install.sh keeps a NONINTERACTIVE path"; fi

# 7. Behavioral: bare curl|sudo bash signposts and exits non-zero (no install)
echo ""
echo "# Running bare curl|sudo bash (expect signpost + non-zero exit)..."
RESULT=$(remote "curl -fsSL $RAW | sudo bash -- >/tmp/fagents-cu.out 2>&1; echo EXIT=\$?; cat /tmp/fagents-cu.out" 2>/dev/null)

if echo "$RESULT" | grep -q 'fagents.ai/install/'; then
    ok "bare curl|bash signposts to fagents.ai/install/"
else
    not_ok "bare curl|bash signposts to fagents.ai/install/"
    echo "$RESULT" | head -20 | sed 's/^/#   /'
fi

EXIT_CODE=$(echo "$RESULT" | grep -oE 'EXIT=[0-9]+' | head -1 | cut -d= -f2)
if [[ "${EXIT_CODE:-0}" -ne 0 ]]; then
    ok "bare curl|bash exits non-zero"
else
    not_ok "bare curl|bash exits non-zero (got EXIT=$EXIT_CODE)"
fi

echo ""
echo "# $PASS passed, $FAIL failed ($NUM total)"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
