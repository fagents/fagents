# fagents-mcp: sanitize prompt-injection-smuggling Unicode in email path

**Date:** 2026-05-18
**Repos changed:** fagents-mcp

## Commits to pull

```
fagents-mcp:  910ec09   Sanitize prompt-injection-smuggling Unicode in email path
```

## What changed

Email is the only inbound channel without an identity gate (telegram / whatsapp / nostr are all allow-listed by sender id/jid/npub). Hostile email senders can smuggle invisible payloads to agents via Unicode classes that render as nothing but can carry arbitrary ASCII (the "tag block" U+E0000-7F mirrors ASCII as invisible glyphs; variation selectors U+FE00-F / U+E0100-1EF can carry payloads via GoodFire-style attacks; bidi controls hide content; zero-width chars split tokens).

The fix adds a `sanitizeText()` helper that strips four dangerous Unicode classes -- and ONLY those -- so Finnish characters, emoji, CJK, and accents all pass through untouched. It is applied at the choke points in `imap.ts` where agent-visible email metadata exits the module:

- **`formatAddr`**: name + address (covers from / to / cc in every code path -- `listMessages`, `searchMessages`, `getMessage`, `checkNewEmail`).
- **`envelopeToEntry`** (list/search): subject + messageId.
- **`getMessage`** (read): subject + messageId + text + html + every attachment filename + every attachment contentType.
- **`downloadAttachment`**: returned contentType.

Out of scope: structural HTML sanitization (tag stripping). The flat-string sanitize catches Unicode smuggling but does not strip `<script>` etc. Agents typically rely on `.text`; HTML hardening is a separate concern.

Classes stripped (full coverage of Node's `\p{Bidi_Control}` enumeration verified):
- Zero-width: U+200B/C/D, U+2060, U+FEFF
- Bidi controls: U+061C, U+200E/F, U+202A-E, U+2066-9
- Variation selectors: U+FE00-F, U+E0100-1EF
- Tag block: U+E0000-7F

57 vitest assertions pass (was 26). `tsc --noEmit` clean.

## Setup steps

All commands run as root on the fagents host.

```bash
INFRA_USER="fagents"
INFRA_HOME=$(eval echo "~$INFRA_USER")
MCP_DIR="$INFRA_HOME/workspace/fagents-mcp"
```

### 1. Pull fagents-mcp

```bash
cd "$MCP_DIR" && sudo -Hu "$INFRA_USER" git pull
```

### 2. Rebuild

No new runtime deps -- `package.json` unchanged. Plain TypeScript recompile:

```bash
sudo -u "$INFRA_USER" bash -c "cd '$MCP_DIR' && npm run build"
```

(Run `npm install` first only if `package-lock.json` shows drift after the pull.)

### 3. Restart MCP service

Self-restart (do NOT stop+start):

```bash
sudo systemctl restart fagents-mcp
```

## Doctor

```bash
# 1. Service is running
systemctl is-active --quiet fagents-mcp && echo "ok: fagents-mcp running" || echo "FAIL"

# 2. Sanitizer is present in the compiled output
sudo -u "$INFRA_USER" grep -q "DANGEROUS" "$MCP_DIR/dist/sanitize.js" && echo "ok: sanitize compiled" || echo "FAIL: sanitize.js missing"

# 3. Live smoke: have an allowed sender send an email with subject "test \u{200B}A\u{200B}B"
#    (or any subject containing ZWSP) and verify that read_email's returned
#    subject is "test AB" (zero-width stripped) -- the agent will see the
#    sanitized value in any read_email / list_emails / get_email response.
```

## Rollback

If something breaks:

```bash
cd "$MCP_DIR" && sudo -Hu "$INFRA_USER" git revert --no-edit 910ec09
sudo -u "$INFRA_USER" bash -c "cd '$MCP_DIR' && npm run build"
sudo systemctl restart fagents-mcp
```

Pre-revert state: `git log --oneline -5` shows the commit before SANITIZE-SHA.

## Notes

- **No data migration.** Pure code change. Existing emails parse the same; sanitization only affects what the agent SEES.
- **HTML is sanitized as a flat string**, not parsed and tag-stripped. A `<script>` in the body still passes through. Agents that surface raw HTML to an LLM (which today they don't) would want a structural sanitizer added separately.
- **Other comms channels (telegram / whatsapp / nostr / comms) intentionally unchanged.** Identity-gated by allow-lists, so the threat model is different. SECURITY.md doc reference: trust boundaries section.
