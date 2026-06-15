#!/bin/bash
# test-blob-roundtrip.sh -- unit-test install.sh's config-blob decode shim.
#
# Exercises the REAL shim in install.sh via FAGENTS_INSTALL_DRYRUN, which skips
# the root check and, after decoding + allowlisting the blob, dumps the env plus
# the argv that would reach the installer, then exits before cloning. No VM, no
# network, no privilege. Run from anywhere: bash e2e-tests/test-blob-roundtrip.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

PASS=0; FAIL=0; NUM=0
ok()     { NUM=$((NUM+1)); PASS=$((PASS+1)); echo "ok $NUM - $1"; }
not_ok() { NUM=$((NUM+1)); FAIL=$((FAIL+1)); echo "not ok $NUM - $1"; }

# expect/reject: assert $1 (captured output) does / does not contain ERE $2.
expect() { if grep -qE "$2" <<<"$1"; then ok "$3"; else not_ok "$3"; fi; }
reject() { if grep -qE "$2" <<<"$1"; then not_ok "$3"; else ok "$3"; fi; }

# Build a blob exactly as the fagents.ai/install/ page does: base64(gzip(JSON)).
blob() { printf '%s' "$1" | gzip | base64 | tr -d '\n'; }
# Run the shim in dry-run mode (root check skipped). Args pass through verbatim.
dryrun() { FAGENTS_INSTALL_DRYRUN=1 bash "$INSTALL_SH" "$@" 2>&1; }

echo "=== test-blob-roundtrip.sh ==="

# --- 1. Well-formed blob: static + dynamic keys decode and export ---
JSON='{"HUMAN_NAMES_INPUT":"Juho","COMMS_PORT":"9999","AGENT_BACKEND_OPS":"codex","NOSTR_NSEC_INPUT_COMMS":"nsec1x","EMAIL_ENABLE":"1","EMAIL_SMTP_PASS_INPUT":"pw"}'
OUT="$(dryrun "$(blob "$JSON")")"
expect "$OUT" '^HUMAN_NAMES_INPUT=Juho$'        "static key HUMAN_NAMES_INPUT exported"
expect "$OUT" '^COMMS_PORT=9999$'               "static key COMMS_PORT exported"
expect "$OUT" '^AGENT_BACKEND_OPS=codex$'       "dynamic key AGENT_BACKEND_OPS exported"
expect "$OUT" '^NOSTR_NSEC_INPUT_COMMS=nsec1x$' "dynamic key NOSTR_NSEC_INPUT_COMMS exported"
expect "$OUT" '^EMAIL_ENABLE=1$'                "email gate EMAIL_ENABLE exported"
expect "$OUT" '^NONINTERACTIVE=1$'              "blob path sets NONINTERACTIVE=1"

# --- 2. Malicious keys dropped: the allowlist is the boundary ---
EVIL='{"COMMS_PORT":"9999","LD_PRELOAD":"/evil.so","PATH":"/evil","AGENT_BACKEND_BAD; rm -rf /":"x"}'
OUT="$(dryrun "$(blob "$EVIL")")"
expect "$OUT" '^COMMS_PORT=9999$'             "good key exported alongside rejected ones"
reject "$OUT" '^LD_PRELOAD='                  "LD_PRELOAD rejected"
reject "$OUT" '^PATH=.*/evil'                 "PATH not clobbered by blob"
reject "$OUT" '^AGENT_BACKEND_BAD'            "metachar dynamic key rejected (bad suffix)"
expect "$OUT" 'ignoring unrecognized config key' "shim warns on non-allowlisted keys"

# --- 3. Legacy options: a leading '-' is NOT decoded as a blob, and "$@" forwards ---
OUT="$(NONINTERACTIVE=1 FAGENTS_INSTALL_DRYRUN=1 bash "$INSTALL_SH" --skip-claude-auth --comms-port 9754 2>&1)"
reject "$OUT" 'could not decode'                          "leading-dash arg not decoded as a blob"
expect "$OUT" '^ARGV: --skip-claude-auth --comms-port 9754$' "legacy options forwarded to installer"

# --- 4. A blob and a trailing legacy option coexist ---
OUT="$(dryrun "$(blob '{"COMMS_PORT":"8888"}')" --verbose)"
expect "$OUT" '^COMMS_PORT=8888$' "blob decodes when followed by a legacy option"
expect "$OUT" '^ARGV: --verbose$' "trailing legacy option forwarded after blob shift"

# --- 5. Malformed blobs fail closed (non-zero, no decode) ---
OUT="$(dryrun 'aGVsbG8K')"; rc=$?   # valid base64 ("hello"), not gzip
if [[ $rc -ne 0 ]] && grep -q 'could not decode' <<<"$OUT"; then
    ok "non-gzip blob errors and exits non-zero"
else
    not_ok "non-gzip blob errors and exits non-zero"
fi
OUT="$(dryrun "$(blob '"juststring"')")"; rc=$?   # valid gzip, JSON but not an object
if [[ $rc -ne 0 ]] && grep -q 'did not contain a JSON object' <<<"$OUT"; then
    ok "non-object JSON blob rejected"
else
    not_ok "non-object JSON blob rejected"
fi

# --- 6. No config at all: signpost to fagents.ai/install/, exit non-zero ---
OUT="$(dryrun)"; rc=$?   # no blob, no NONINTERACTIVE
if [[ $rc -ne 0 ]] && grep -q 'fagents.ai/install/' <<<"$OUT"; then
    ok "bare run signposts to fagents.ai/install/ and exits non-zero"
else
    not_ok "bare run signposts to fagents.ai/install/ and exits non-zero"
fi

# --- 7. Shell-injection regression: malicious-apostrophe + value validation ---
# Names with shell metacharacters used to flow into `su -c "...'$name'..."` and
# break out as code. Both installers now (a) validate the charset up-front and
# (b) quote the add-agent arg with `printf '%q'` as defense-in-depth. The
# `eval echo "~$user"` idiom is gone everywhere (replaced by `lookup_home`).
TEAM_LINUX="$(cat "$SCRIPT_DIR/../install-team.sh")"
TEAM_MACOS="$(cat "$SCRIPT_DIR/../install-team-macos.sh")"
expect "$TEAM_LINUX" 'Invalid agent name'              "install-team.sh validates agent name charset"
expect "$TEAM_MACOS" 'Invalid agent name'              "install-team-macos.sh validates agent name charset"
expect "$TEAM_LINUX" 'Invalid COMMS_PORT'              "install-team.sh validates COMMS_PORT is numeric"
expect "$TEAM_MACOS" 'Invalid COMMS_PORT'              "install-team-macos.sh validates COMMS_PORT is numeric"
expect "$TEAM_LINUX" "printf '%q'"                     "install-team.sh quotes add-agent arg with printf %q"
expect "$TEAM_MACOS" "printf '%q'"                     "install-team-macos.sh quotes add-agent arg with printf %q"
reject "$TEAM_LINUX" '^[^#]*eval echo "~'                    "install-team.sh has no eval echo home-dir sinks"
reject "$TEAM_MACOS" '^[^#]*eval echo "~'                    "install-team-macos.sh has no eval echo home-dir sinks"
reject "$(cat "$SCRIPT_DIR/../install-email.sh")" '^[^#]*eval echo "~' "install-email.sh has no eval echo home-dir sinks"

# Mechanism check: `printf '%q'` + `bash -c` round-trips a malicious-apostrophe
# value as a SINGLE argument (no injection, no side effect).
_INJECT="x'; touch /tmp/FAGENTS_INJECT_$$; #"
_QINJECT=$(printf '%q' "$_INJECT")
_RESULT=$(bash -c "printf '%s' $_QINJECT" 2>/dev/null)
if [[ "$_RESULT" == "$_INJECT" && ! -e "/tmp/FAGENTS_INJECT_$$" ]]; then
    ok "printf %q safely round-trips a malicious-apostrophe value (no injection)"
else
    not_ok "printf %q safely round-trips a malicious-apostrophe value (no injection)"
    rm -f "/tmp/FAGENTS_INJECT_$$"
fi

echo ""
echo "# $PASS passed, $FAIL failed ($NUM total)"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
