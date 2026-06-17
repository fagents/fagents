#!/bin/bash
# test-page-shape.sh -- contract test between install/index.html and install.sh.
#
# The configure page's buildConfig() emits a JSON blob; install.sh decodes it
# through ALLOWED_STATIC + a dynamic-prefix regex. If the page emits a key the
# shim never allowlisted, the field is silently dropped -- the installer never
# sees it, the user never finds out. This test guards that seam in pure bash
# (no Node, no browser, no VM). Pair it with test-blob-roundtrip.sh, which
# covers the shim itself with hand-crafted blobs.
#
# Run from anywhere: bash e2e-tests/test-page-shape.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAGE="$SCRIPT_DIR/../install/index.html"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

PASS=0; FAIL=0; NUM=0
ok()     { NUM=$((NUM+1)); PASS=$((PASS+1)); echo "ok $NUM - $1"; }
not_ok() { NUM=$((NUM+1)); FAIL=$((FAIL+1)); echo "not ok $NUM - $1"; }

echo "=== test-page-shape.sh ==="

# Static keys the page emits: cfg.HUMAN_NAMES_INPUT (dotted) or cfg['LITERAL']
# (bracket-quoted, with no '+' after the closing quote -- the '+' marks dynamic).
emitted_static=$( {
    grep -oE "cfg\.[A-Z][A-Z0-9_]+"                       "$PAGE" | sed 's/^cfg\.//'
    grep -oE "cfg\[['\"][A-Z][A-Z0-9_]+['\"]\]"           "$PAGE" | sed -E "s/cfg\[['\"]//;s/['\"]\]\$//"
} | sort -u)

# Dynamic-prefix keys: cfg['PREFIX_' + ...] or cfg["PREFIX_" + ...]
# The trailing _'+ (single or double quote, then '+') is what distinguishes a
# dynamic emission from a static one.
emitted_dyn=$(grep -oE "cfg\[['\"][A-Z][A-Z0-9_]+_['\"] *\+" "$PAGE" \
    | sed -E "s/cfg\[['\"](.+)_['\"] *\+\$/\1/" | sort -u)

# Allowlisted static keys, gathered from the multi-line ALLOWED_STATIC= literal.
allowed_static=$(awk '/ALLOWED_STATIC="/{p=1} p{print; if(/"$/) exit}' "$INSTALL_SH" \
    | tr -d '\\"' | sed 's/^.*ALLOWED_STATIC=//' \
    | tr -s '[:space:]' '\n' | grep -E '^[A-Z][A-Z0-9_]+$' | sort -u)

# Allowlisted dynamic prefixes, extracted from the _allowed_key regex.
allowed_dyn=$(grep -oE '\(AGENT_BACKEND\|NOSTR_NSEC_INPUT\|NOSTR_ALLOWED_NPUBS_INPUT\)' "$INSTALL_SH" \
    | head -1 | tr -d '()' | tr '|' '\n' | sort -u)

# Sanity: both sides parsed something.
parsed() { if [[ -n "$1" ]]; then ok "$2"; else not_ok "$2"; fi; }
parsed "$emitted_static" "parsed emitted static keys from index.html"
parsed "$emitted_dyn"    "parsed emitted dynamic-prefix keys from index.html"
parsed "$allowed_static" "parsed ALLOWED_STATIC from install.sh"
parsed "$allowed_dyn"    "parsed dynamic prefix regex from install.sh"

# Contract: page-emitted keys MUST be a subset of allowlisted keys.
bad_static=$(comm -23 <(echo "$emitted_static") <(echo "$allowed_static"))
if [[ -z "$bad_static" ]]; then
    ok "every cfg.<KEY> in buildConfig is in ALLOWED_STATIC"
else
    not_ok "every cfg.<KEY> in buildConfig is in ALLOWED_STATIC"
    echo "$bad_static" | sed 's/^/#   not allowlisted: /'
fi

bad_dyn=$(comm -23 <(echo "$emitted_dyn") <(echo "$allowed_dyn"))
if [[ -z "$bad_dyn" ]]; then
    ok "every cfg['<PREFIX>_'+...] in buildConfig matches the dynamic regex"
else
    not_ok "every cfg['<PREFIX>_'+...] in buildConfig matches the dynamic regex"
    echo "$bad_dyn" | sed 's/^/#   prefix not in regex: /'
fi

# Bonus: required base keys must always be emitted (catches accidental deletion).
for k in HUMAN_NAMES_INPUT OPS_AGENT_NAME COMMS_AGENT_NAME; do
    if grep -qE "^${k}$" <<<"$emitted_static"; then
        ok "buildConfig emits required key $k"
    else
        not_ok "buildConfig emits required key $k"
    fi
done

# Stale-reference guard: when a UI control is removed from the page, the JS
# accesses it via getElementById/v() must go too -- otherwise the page throws
# at load on the first `.value` of null. Each pattern is exact enough not to
# false-positive against still-valid neighbours (e.g. `tg_openai_voice_key`).
absent() {
    if grep -qF -- "$1" "$PAGE"; then
        not_ok "$2"
    else
        ok "$2"
    fi
}

# Removed in this feature: Codex auth mode <select>, the OpenAI key input
# + its label, the codex_oauth_hint paragraph, and the _isCodexAuthorized
# function.
absent 'id="codex_auth_mode"'            "stale: <select id=codex_auth_mode> removed"
absent 'id="openai_key"'                 "stale: <input id=openai_key> removed"
absent 'id="openai_key_label"'           "stale: <label id=openai_key_label> removed"
absent 'id="codex_oauth_hint"'           "stale: <p id=codex_oauth_hint> removed"
absent '_isCodexAuthorized'              "stale: _isCodexAuthorized function removed"
# JS access sites for the removed ids (both quote styles).
absent "getElementById('codex_auth_mode')" "stale: getElementById('codex_auth_mode') removed"
absent 'getElementById("codex_auth_mode")' "stale: getElementById(\"codex_auth_mode\") removed"
absent "getElementById('openai_key')"      "stale: getElementById('openai_key') removed"
absent 'getElementById("openai_key")'      "stale: getElementById(\"openai_key\") removed"
absent "v('openai_key')"                   "stale: v('openai_key') removed"
absent 'v("openai_key")'                   "stale: v(\"openai_key\") removed"

echo ""
echo "# $PASS passed, $FAIL failed ($NUM total)"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
