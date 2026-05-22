# fagents-cli: Nostr followers (kind:3 aggregation for analytics)

**Date:** 2026-05-22
**Repos changed:** fagents-cli

## Commits to pull

```
fagents-cli:  77bd268   Add nostr.mjs followers (kind:3 #p aggregation)
```

## What changed

Previous DEPLOYLOG shipped `nostr.mjs get`. This is triage item #4 of the original four-feature triage (added mid-cycle for analytics): a read-only command that counts how many Nostr pubkeys have the target pubkey in their kind:3 contact lists.

```
nostr.mjs followers <npub> [--limit <n>] [--list]
```

The CLI issues one REQ per relay in `NOSTR_RELAYS` for `{kinds:[3], #p:[targetHex], limit:N}`, aggregates verified results, dedupes by author + latest `created_at`, and emits `{npub, count, capped}` -- with optional `followers: [<npub>, ...]` array via `--list`. Read-only; no nsec loaded; no events published.

Defenses at the CLI (layered):
- **Target decoder**: `decodeNpub(npubArg)` rejects malformed input as `bad-target-npub` pre-network.
- **`--limit` strict canonical decimal**: `parseInt('1abc', 10) === 1` silently truncates otherwise; the `String(n) === v` check catches it. Range `[1, 10000]`.
- **`verifyEvent`**: every received event must pass schnorr sig verification before counting (rejects relay-fabricated frames).
- **`ev.kind === 3` post-receive gate** (the key defense): the relay-side `kinds:[3]` filter is a HINT, not a guarantee. A misbehaving relay could return any signed event with a matching p-tag (kind:1 mention, kind:7 reaction, etc.). Without this explicit gate, our follower count would conflate "followers" with "anyone who has ever p-tagged the target in any event". Test 218a-c regression-tests this by serving three events under the same target p-tag -- one valid kind:1 mention, one valid kind:7 reaction, and one valid kind:3 -- and verifying that only the kind:3 counts (`count=1`). The invariant is "non-kind:3 events with a matching p-tag do not inflate the count", not "kind:3 events are always rejected".
- **Post-receive p-tag membership check**: even after `verifyEvent + ev.kind === 3`, we additionally check that the event's `tags` actually contain `["p", targetHex]` -- defends against a relay that returns kind:3 events not matching our `#p` filter (filter-cheating).
- **Author dedup by `ev.pubkey` + latest `created_at`**: same author's kind:3 from multiple relays dedups to one entry. NOTE: this is freshness only among p-tagged kind:3 events; if an author later unfollowed by publishing a kind:3 WITHOUT our p-tag, our `#p` filter doesn't see that event, and the old p-tagged one is still what we count. The SKILL warns about this limitation explicitly.
- **`capped` reflects raw EVENT frame count, not accepted-frame count**: incremented at the top of the perEvent callback BEFORE any validation. A relay that returned exactly `--limit` frames hit its visibility limit regardless of how many our validators accepted -- there may be more p-tagged kind:3 events beyond the cap we never saw. Test 220d-f covers this.
- **`--list` output sorted lexicographically by hex pubkey**: deterministic ordering across runs (Map insertion order depends on async relay arrival timing).

26 new test blocks (groups 212-237), 62 new assertions. **561/561 PASS** (up from 499). Includes the SECURITY-CRITICAL regressions for the kind:3 gate (218a-c) and the capped-on-raw-count semantic (220d-f).

The SKILL section between `get` and `reply` carries three CRITICAL warnings the agent must internalize:
1. **GROSS not real followers**: includes sybils, inactive accounts, and silent-unfollow stale entries the `#p` query structurally cannot see.
2. **Relay-bounded**: count is bounded by what `NOSTR_RELAYS` knows; niche relays will be missed.
3. **Capped = lower bound**: `capped:true` means "at least N", never "exactly N".

Out of scope (deferred):
- Cursor-walk via `since` pagination for >limit followers (`--all-pages` future flag)
- Per-relay breakdown (`--by-relay`) -- env-var workaround `NOSTR_RELAYS=wss://just-one` covers the debugging case
- `--sort` ordering options
- Follower trend over time (requires persistent storage)
- NIP-65 relay-list awareness (figuring out which relays a target's followers actually live on)

## Prerequisites

- No new runtime deps.
- No new env vars. `followers` uses the existing `NOSTR_RELAYS` from `nostr.env`. Optional `NOSTR_FOLLOWERS_TIMEOUT_MS` (default 8000) override.

## Setup steps

All commands run as root on the fagents host.

```bash
INFRA_USER="fagents"
INFRA_HOME=$(eval echo "~$INFRA_USER")
CLI_DIR="$INFRA_HOME/workspace/fagents-cli"
```

### 1. Preflight chown + pull fagents-cli

Per the DEPLOYLOG README template (`3c03acf`):

```bash
sudo chown -R "$INFRA_USER:fagent" "$INFRA_HOME/repos"
sudo chown -R "$INFRA_USER:fagent" "$INFRA_HOME/workspace"
sudo -Hu "$INFRA_USER" git -C "$CLI_DIR" pull origin main
```

No `npm install` (no new deps).

### 2. Re-render the nostr skill for each agent

```bash
for COMMS_USER in ftf ftl ftw; do
    AGENT_DIR="$INFRA_HOME/.agents/$COMMS_USER"
    [ -d "$AGENT_DIR/skills/nostr" ] || continue
    sudo sed "s|__CLI_DIR__|$CLI_DIR|g" "$CLI_DIR/nostr/SKILL.md" \
        | sudo tee "$AGENT_DIR/skills/nostr/SKILL.md" >/dev/null
    sudo chown "$INFRA_USER:fagent" "$AGENT_DIR/skills/nostr/SKILL.md"
    sudo chmod 644 "$AGENT_DIR/skills/nostr/SKILL.md"
done
```

Existing sudoers rule (`sudo -u fagents $CLI_DIR/nostr.mjs *`) covers the new `followers` subcommand.

### 3. No daemon restart

`nostr.mjs serve` is unchanged. `followers` is a one-shot CLI invocation.

## Doctor

```bash
INFRA_HOME=$(eval echo "~fagents")
CLI_DIR="$INFRA_HOME/workspace/fagents-cli"

# 1. followers subcommand visible in help output
sudo -Hu fagents "$CLI_DIR/nostr.mjs" help | python3 -c "
import json, sys
cmds = json.load(sys.stdin)['commands']
checks = [c for c in cmds if c.startswith('followers ')]
print(f'ok: followers subcommand in help' if len(checks) == 1 else f'FAIL: expected 1 followers entry, got {len(checks)}')
"

# 2. Each agent's installed SKILL.md has the new section + at least one of the 3 warnings
for u in ftf ftl ftw; do
    AD="$INFRA_HOME/.agents/$u"
    [ -f "$AD/skills/nostr/SKILL.md" ] || continue
    has_section=$(grep -c '^## Reading follower count' "$AD/skills/nostr/SKILL.md")
    has_warning=$(grep -c 'GROSS follower count' "$AD/skills/nostr/SKILL.md")
    if [ "$has_section" = "1" ] && [ "$has_warning" = "1" ]; then
        echo "ok: $u SKILL.md has followers section + GROSS warning"
    else
        echo "FAIL: $u SKILL.md missing followers section -- re-run step 2"
    fi
done

# 3. Negative-path smokes (no network required):
#    no positional -> missing-target-npub
sudo -Hu fagents "$CLI_DIR/nostr.mjs" followers 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read().strip())
    print('ok: missing positional rejected' if d.get('error') == 'missing-target-npub' else f'FAIL: unexpected: {d}')
except Exception as e:
    print(f'FAIL: malformed: {e}')
"

#    bad-limit-value (--limit 1abc) exercises canonical-decimal truncation guard
SELF_NPUB=$(sudo -Hu fagents "$CLI_DIR/nostr.mjs" whoami | python3 -c "import json,sys; print(json.load(sys.stdin)['npub'])")
sudo -Hu fagents "$CLI_DIR/nostr.mjs" followers "$SELF_NPUB" --limit 1abc 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read().strip())
    print('ok: --limit 1abc rejected as bad-limit-value' if d.get('error') == 'bad-limit-value' else f'FAIL: unexpected: {d}')
except Exception as e:
    print(f'FAIL: malformed: {e}')
"
```

A live `followers <real-npub>` smoke is read-only but still costs a relay round-trip per configured relay; doctor stays argv-only.

## Rollback

```bash
cd "$CLI_DIR" && sudo -Hu "$INFRA_USER" git revert --no-edit 77bd268
for u in ftf ftl ftw; do
    AD="$INFRA_HOME/.agents/$u"
    [ -d "$AD/skills/nostr" ] || continue
    sudo sed "s|__CLI_DIR__|$CLI_DIR|g" "$CLI_DIR/nostr/SKILL.md" \
        | sudo tee "$AD/skills/nostr/SKILL.md" >/dev/null
done
```

No daemon restart for revert. `followers` publishes nothing, so there's no published-event aftermath to clean up.

## Notes

- **The output is gross, relay-bounded, and capped-aware by design.** Operators evaluating this for analytics should treat the number as a structural lower bound, never a definitive audience size. The SKILL warns the agent to label the number explicitly when emitting it to humans.
- **No NOSTR_FOLLOWERS_ALLOWED_TARGETS by design** -- read-only; skill carries the trust posture.
- **Manual dev-side smoke** performed against damus.io / nos.lol / relay.primal.net with a throwaway nsec: (1) queried followers for a well-known public npub (fiatjaf) -> `{count: 824, capped: false}` (824 unique followers across the configured relays, no relay hit the default 1000 cap); (2) queried for a freshly-generated never-followed npub -> `{count: 0, capped: false}`; (3) `--limit 1abc` rejected as `bad-limit-value` (canonical-decimal guard); (4) missing positional rejected as `missing-target-npub`; (5) `--list --limit 5` against the same well-known npub returned `{count: 11, capped: true}` with the followers array sorted deterministically by underlying hex pubkey (capped=true because the cap of 5 was hit on multiple relays; final unique count of 11 reflects post-dedup aggregation across all three relays).
- **The capped semantic is a load-bearing design choice**: a relay returning exactly `--limit` frames means visibility ended at the cap. Whether some frames failed our validation doesn't change that visibility limit. Test 220d-f locks this invariant.
