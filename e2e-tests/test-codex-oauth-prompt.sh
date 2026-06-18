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
equals()   { if [[ "$1" == "$2" ]];   then ok "$3"; else not_ok "$3 (got: $1)"; fi; }

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

# ----------------------------------------------------------------------
# WRITE_CODEX_MODEL_OVERRIDE: install-team*.sh writes `model = "gpt-5.5"`
# to each codex agent's config.toml after `codex login --device-auth`
# succeeds, because codex's default `gpt-5.3-codex` is rejected on
# ChatGPT subscription accounts (auth_mode=chatgpt). These assertions
# extract the marked block from each installer, eval it in an isolated
# `$HOME`, and verify write-when-absent / idempotency / chmod 600.
# ----------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Pull the helper snippet out of an installer. The block has the shape:
#   # WRITE_CODEX_MODEL_OVERRIDE: ... (comments)
#   <wrapper> "CODEX_HOME='...' bash" <<'WRITE_CODEX_MODEL_OVERRIDE_BODY'
#       <inner snippet>
#   WRITE_CODEX_MODEL_OVERRIDE_BODY
# We emit the inner snippet so the test can `eval` it as plain bash.
# CODEX_HOME is set by the test (mimicking what the wrapper does in
# production) so the snippet uses the same `"$CODEX_HOME/config.toml"`
# resolution path that the real install does.
extract_override() {
    awk '
        /<<.{0,2}WRITE_CODEX_MODEL_OVERRIDE_BODY.{0,2}$/ { in_block=1; next }
        in_block && /^WRITE_CODEX_MODEL_OVERRIDE_BODY[[:space:]]*$/ { exit }
        in_block { print; next }
    ' "$1"
}

run_override_test() {
    local label="$1" installer="$2"
    local snippet
    snippet=$(extract_override "$installer")
    if [[ -z "$snippet" ]]; then
        not_ok "[$label] extract WRITE_CODEX_MODEL_OVERRIDE block from $(basename "$installer")"
        return
    fi
    ok "[$label] extracted WRITE_CODEX_MODEL_OVERRIDE block from $(basename "$installer")"

    local tmphome
    tmphome=$(mktemp -d -t codex-override.XXXXXX)
    mkdir -p "$tmphome/.codex"
    # CODEX_HOME = what the production wrapper sets via `CODEX_HOME='$codex_home' bash`.
    export CODEX_HOME="$tmphome/.codex"

    # Case 1: empty config.toml -> helper prepends `model = "gpt-5.5"`.
    : > "$CODEX_HOME/config.toml"
    eval "$snippet"
    local first
    first=$(head -1 "$CODEX_HOME/config.toml")
    equals "$first" 'model = "gpt-5.5"' "[$label] writes model = \"gpt-5.5\" when absent"

    # Case 2: existing `model = "..."` is preserved (idempotent).
    echo 'model = "gpt-6-existing"' > "$CODEX_HOME/config.toml"
    eval "$snippet"
    first=$(head -1 "$CODEX_HOME/config.toml")
    equals "$first" 'model = "gpt-6-existing"' "[$label] preserves existing model line (idempotent)"

    # Case 3: file ends up chmod 600.
    : > "$CODEX_HOME/config.toml"
    eval "$snippet"
    local mode
    mode=$(stat -f '%Lp' "$CODEX_HOME/config.toml" 2>/dev/null \
           || stat -c '%a' "$CODEX_HOME/config.toml" 2>/dev/null)
    equals "$mode" "600" "[$label] config.toml is chmod 600"

    unset CODEX_HOME
    rm -rf "$tmphome"
}

run_override_test "linux"  "$REPO_ROOT/install-team.sh"
run_override_test "macos"  "$REPO_ROOT/install-team-macos.sh"

# Static drift guard: both installers must contain the marker AND the
# literal `gpt-5.5` (catches one being bumped without the other).
for installer in install-team.sh install-team-macos.sh; do
    if grep -q "WRITE_CODEX_MODEL_OVERRIDE" "$REPO_ROOT/$installer"; then
        ok "[drift] $installer has WRITE_CODEX_MODEL_OVERRIDE marker"
    else
        not_ok "[drift] $installer has WRITE_CODEX_MODEL_OVERRIDE marker"
    fi
    if grep -q 'gpt-5.5' "$REPO_ROOT/$installer"; then
        ok "[drift] $installer references gpt-5.5"
    else
        not_ok "[drift] $installer references gpt-5.5"
    fi
done

echo ""
echo "# $PASS passed, $FAIL failed ($NUM total)"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
