#!/bin/bash
# fagents installer — curlable bootstrap script
#
# Usage:
#   Generate a one-line install command at https://fagents.ai/install/, then run it:
#     curl -fsSL https://fagents.ai/install.sh | sudo bash -s -- <config-blob>
#   Automation can instead set NONINTERACTIVE=1 with the required env vars and
#   optionally pass legacy options (--comms-port, --skip-claude-auth, ...).
#
# <config-blob> = base64(gzip(JSON)); decoded and exported via an allowlist
# (never eval'd) so a tampered blob cannot inject env into the root installer.

set -euo pipefail

echo ""
echo "  fagents — free agents"
echo "  https://fagents.ai"
echo ""

# ── Preflight ──
# FAGENTS_INSTALL_DRYRUN is a unit-test seam (never set in production): it skips
# the root requirement and, after blob decode, dumps env and exits before any
# privileged work (see below). The real install always requires root.
if [[ "$(id -u)" -ne 0 && -z "${FAGENTS_INSTALL_DRYRUN:-}" ]]; then
    echo "ERROR: This script must be run as root (use sudo)." >&2
    exit 1
fi

# ── Platform detection ──
OS="$(uname -s)"
case "$OS" in
    Linux)  INSTALLER="install-team.sh" ;;
    Darwin) INSTALLER="install-team-macos.sh" ;;
    *)      echo "ERROR: Unsupported OS: $OS" >&2; exit 1 ;;
esac

# ── Bare-run signpost (before any prereq work) ──
# No config blob (a non-dash first arg) and no NONINTERACTIVE env => nothing to
# install. Point at the config page and exit WITHOUT touching apt/Homebrew.
if [[ ( -z "${1:-}" || "${1:0:1}" == "-" ) && -z "${NONINTERACTIVE:-}" ]]; then
    echo "No configuration provided." >&2
    echo "" >&2
    echo "Generate your one-line install command at:" >&2
    echo "    https://fagents.ai/install/" >&2
    echo "" >&2
    echo "(Automation: set NONINTERACTIVE=1 with the required env vars.)" >&2
    exit 1
fi

# ── Prerequisites ──
if [[ "$OS" == "Darwin" ]]; then
    # macOS: can't brew install as root — check only
    _missing=()
    for cmd in git python3 curl jq; do
        command -v "$cmd" &>/dev/null || _missing+=("$cmd")
    done
    if [[ ${#_missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing prerequisites: ${_missing[*]}" >&2
        echo "       Install with Homebrew (as your normal user, not root):" >&2
        echo "       brew install ${_missing[*]}" >&2
        exit 1
    fi
else
    # Linux: install missing prereqs via apt
    _missing=()
    for cmd in git python3 curl jq; do
        command -v "$cmd" &>/dev/null || _missing+=("$cmd")
    done
    if [[ ${#_missing[@]} -gt 0 ]]; then
        echo "Installing prerequisites: ${_missing[*]}"
        apt-get update -qq 2>/dev/null || true
        apt-get install -y "${_missing[@]}" 2>/dev/null || true
        for cmd in "${_missing[@]}"; do
            if ! command -v "$cmd" &>/dev/null; then
                echo "ERROR: '$cmd' is required but could not be installed." >&2
                echo "       Try: apt-get install -y $cmd" >&2
                exit 1
            fi
        done
    fi
fi

# ── Config blob decode ──
# A base64 blob never starts with '-', so a leading '-' means legacy options
# that pass straight through to the installer via "$@". We decode the blob and
# export each allowlisted key; we NEVER eval, so a tampered/malicious blob
# cannot inject PATH / LD_PRELOAD / IFS into the root-running installer.

# Static contract keys (exact match). Keep in sync with install-team*.sh.
ALLOWED_STATIC="HUMAN_NAMES_INPUT OPS_AGENT_NAME COMMS_AGENT_NAME COMMS_PORT \
  CLAUDE_TOKEN CLAUDE_OAUTH_CODE CLAUDE_OAUTH_VERIFIER \
  SKIP_CLAUDE_AUTH CODEX_AUTH_MODE \
  TELEGRAM_ENABLE TELEGRAM_BOT_TOKEN_INPUT TELEGRAM_ALLOWED_INPUT \
  X_ENABLE X_BEARER_TOKEN_INPUT X_CONSUMER_KEY_INPUT X_CONSUMER_SECRET_INPUT \
  X_ACCESS_TOKEN_INPUT X_ACCESS_TOKEN_SECRET_INPUT \
  OPENAI_API_KEY_INPUT OPENAI_OAUTH_CODE OPENAI_OAUTH_VERIFIER \
  NOSTR_ENABLE NOSTR_RELAYS_INPUT \
  WHATSAPP_ENABLE WHATSAPP_SELF_JID_INPUT \
  EMAIL_ENABLE EMAIL_FROM_INPUT EMAIL_SMTP_HOST_INPUT EMAIL_SMTP_PORT_INPUT \
  EMAIL_SMTP_USER_INPUT EMAIL_SMTP_PASS_INPUT EMAIL_IMAP_HOST_INPUT \
  EMAIL_IMAP_PORT_INPUT EMAIL_IMAP_USER_INPUT EMAIL_IMAP_PASS_INPUT"

# Per-agent dynamic keys: AGENT_BACKEND_<UPPER>, NOSTR_NSEC_INPUT_<UPPER>,
# NOSTR_ALLOWED_NPUBS_INPUT_<UPPER>. The strict [A-Z0-9_]+ suffix keeps the
# allowlist a real boundary (PATH/LD_PRELOAD/IFS cannot match).
_allowed_key() {
    case " $ALLOWED_STATIC " in *" $1 "*) return 0 ;; esac
    [[ "$1" =~ ^(AGENT_BACKEND|NOSTR_NSEC_INPUT|NOSTR_ALLOWED_NPUBS_INPUT)_[A-Z0-9_]+$ ]]
}

if [[ -n "${1:-}" && "${1:0:1}" != "-" ]]; then
    _blob="$1"; shift   # consume blob; any remaining "$@" are legacy options
    _json="$(printf '%s' "$_blob" | base64 -d 2>/dev/null | gunzip 2>/dev/null)" \
        || { echo "ERROR: could not decode config blob (expected base64(gzip(JSON)))." >&2; exit 1; }
    printf '%s' "$_json" | jq -e 'type == "object"' >/dev/null 2>&1 \
        || { echo "ERROR: config blob did not contain a JSON object." >&2; exit 1; }
    while IFS= read -r _k; do
        if _allowed_key "$_k"; then
            _v="$(printf '%s' "$_json" | jq -r --arg k "$_k" '.[$k] // empty')"
            [[ -n "$_v" ]] && export "$_k=$_v"   # quoted: value is data, not code
        else
            echo "  (ignoring unrecognized config key: $_k)" >&2
        fi
    done < <(printf '%s' "$_json" | jq -r 'keys[]')
    export NONINTERACTIVE=1
fi

# Test seam (unit tests only, never set in production): after the blob is
# decoded + allowlisted, dump the resulting env plus the argv that would reach
# the installer (proves blob-shift + legacy-option passthrough), then exit.
if [[ -n "${FAGENTS_INSTALL_DRYRUN:-}" ]]; then
    env
    printf 'ARGV:'; printf ' %s' "$@"; printf '\n'
    exit 0
fi

# ── Clone ──
INSTALL_DIR="/tmp/fagents-install-$$"
trap 'rm -rf "$INSTALL_DIR"' EXIT

echo "Fetching fagents..."
git clone --depth 1 --quiet https://github.com/fagents/fagents.git "$INSTALL_DIR"

# ── Run installer (env-only; legacy options in "$@" pass through) ──
echo ""
"$INSTALL_DIR/$INSTALLER" "$@"
