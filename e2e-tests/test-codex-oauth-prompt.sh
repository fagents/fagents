#!/bin/bash
# test-codex-oauth-prompt.sh -- verify Codex device-auth prompt survives the
# install execution shape.
#
# When CODEX_AUTH_MODE=oauth, install-team*.sh runs `codex login --device-auth`
# inside `su - "$user" -c "..."` while the install itself was invoked via
# `curl | sudo bash -s -- <blob>`. The risk is the verification URL +
# user code getting swallowed by the pipe or the subshell -- if the user
# can't see the URL, the install hangs forever.
#
# Upstream codex (codex-rs/login/src/device_code_auth.rs::print_device_code_prompt)
# uses `println!` -- i.e. STDOUT, not stderr. The fake codex below matches.
#
# Run from anywhere: bash e2e-tests/test-codex-oauth-prompt.sh

set -uo pipefail

TMPDIR=$(mktemp -d -t codex-oauth-test.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0; FAIL=0; NUM=0
ok()      { NUM=$((NUM+1)); PASS=$((PASS+1)); echo "ok $NUM - $1"; }
not_ok()  { NUM=$((NUM+1)); FAIL=$((FAIL+1)); echo "not ok $NUM - $1"; }
skip()    { NUM=$((NUM+1)); PASS=$((PASS+1)); echo "ok $NUM - $1 # SKIP"; }
# Helpers wrap the cond-then-ok/not_ok branch in an explicit if/else so each
# assertion stays one line without tripping shellcheck SC2015.
contains() { if [[ "$1" == *"$2"* ]]; then ok "$3"; else not_ok "$3"; fi; }
zero()     { if [[ "$1" -eq 0 ]];     then ok "$2"; else not_ok "$2"; fi; }

URL="https://example.test/code"
CODE="TEST-CODE"

# Fake codex: emit the device-auth prompt on stdout (matching real codex's
# println!), sleep briefly, exit 0. Anything other than --device-auth is
# a hard error so the test catches a regression that drops the flag.
cat > "$TMPDIR/codex" <<EOF
#!/bin/bash
set -e
if [[ "\$1" != "login" || "\$2" != "--device-auth" ]]; then
    echo "fake codex: expected 'login --device-auth', got: \$*" >&2
    exit 2
fi
echo "Verification URL: $URL"
echo "User code: $CODE"
sleep "\${CODEX_FAKE_DELAY:-1}"
exit 0
EOF
chmod +x "$TMPDIR/codex"

echo "=== test-codex-oauth-prompt.sh ==="

# --- Shape 1: plain bash -c (the no-root baseline) ---
# Captures combined stdout+stderr. If the URL+code don't survive this,
# the more complex shapes can't possibly work.
out=$(PATH="$TMPDIR:$PATH" bash -c 'codex login --device-auth' 2>&1)
rc=$?
contains "$out" "$URL"  "[bash -c] verification URL reaches captured stream"
contains "$out" "$CODE" "[bash -c] user code reaches captured stream"
zero "$rc"              "[bash -c] wrapper exit code is 0"

# --- Shape 2: sudo + su - <user> -c (the real install wrapping) ---
# Mirrors install-team.sh's `su - "$user" -c "CODEX_HOME=... codex login --device-auth"`.
# Skipped cleanly when no cached sudo: we still want the test to pass for
# devs running it locally on a laptop.
if sudo -n true 2>/dev/null; then
    out=$(sudo -n bash -c "su - \"$USER\" -c 'PATH=\"$TMPDIR:\$PATH\" codex login --device-auth'" 2>&1)
    rc=$?
    contains "$out" "$URL"  "[sudo + su -] verification URL reaches captured stream"
    contains "$out" "$CODE" "[sudo + su -] user code reaches captured stream"
    zero "$rc"              "[sudo + su -] wrapper exit code is 0"
else
    skip "[sudo + su -] skipped (no cached sudo on this host)"
    skip "[sudo + su -] skipped"
    skip "[sudo + su -] skipped"
fi

echo ""
echo "# $PASS passed, $FAIL failed ($NUM total)"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
