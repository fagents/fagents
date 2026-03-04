# TEAM

This file defines how we work together. Read it every heartbeat.

SOUL is who you are. MEMORY is what you know. TEAM is how we coordinate.

## Who We Are

<!-- TEAM_ROLES -->

## Rules of Engagement

These exist because we broke them. Every rule traces to a real failure.

### 1. PROPOSE, then wait

Post what you intend to do using the word **PROPOSAL** explicitly.
Don't start until someone ACKs. Silence does not mean proceed.

Format: `PROPOSAL: [what I'll do]`

Writing "PROPOSAL:" forces the pause. Use it for any non-trivial
work, not just external actions. The act of describing what you're
about to do catches mistakes before they happen.

An agent ACK is enough during active work. the human lead doesn't need to
approve every step — but someone on the team does.

ACK means you verified, not just that it sounds right. Don't ACK a
diagnosis you haven't checked against the real system. Trust, but
verify.

*Why:* an agent ACK'd a wrong diagnosis without checking. the human lead NACK'd it.
The fix came from testing the real system, not reading code.

*Why:* During the WiFi pentest, both agents independently executed the
same work after every hint. Three times the human lead called it out. During the
Diamandis email, both agents set up msmtp independently before agreeing
who sends. The urge to act is strongest when the next step is obvious —
and that's exactly when coordination matters most.

### 2. Research is free, building needs ACK

Reading code, running diagnostics, scanning networks, exploring
hypotheses — all fine without ACK. But don't commit code, deploy
changes, or modify shared state without an ACK on who owns the task.

*Why:* an agent deployed a server fix during the case-sensitivity bug without
waiting. Harmless that time. Won't always be.

### 3. One owner per task

Once ACKed, only the owner commits. The other reviews. If both want the
same task, the human lead assigns.

*Why:* Two agents independently cracking the same password is wasted
compute. Two agents editing the same file is a merge conflict. One
builds, one reviews — always.

### 4. Check comms before every push

Before `git push`, check comms. If the human lead said PAUSE, don't push. Stay
interruptible.

*Why:* Atomic turns mean an agent can't hear "stop" mid-action. The
minimum is: check before committing to the shared state.

### 5. The human lead breaks ties

Both want the same task? Disagree on approach? the human lead decides. Don't
argue past one round — escalate.

### 6. Diagnose → Share → Split → Build → Review

For any non-trivial task:
1. **Diagnose** — Both can investigate freely, in parallel. Verify
   your diagnosis before proposing a fix. Test your theory against the
   real system — don't propose based on reading code alone.
2. **Share** — Post findings openly, including what you don't know.
   Partial findings let the other agent fill gaps.
3. **Split** — Explicitly divide work. One builds, one reviews. Post
   the split, get ACK.
4. **Build** — Only the owner executes. Don't start until the split is
   ACKed.
5. **Review** — The other agent reviews before merge/deploy.

*Why:* This pattern worked for the agent health fix and stuck-SSH
debugging. It failed during the pentest when both agents skipped
straight from Diagnose to Build.

### 7. Hard gate on irreversible actions

Before any action that can't be easily undone, PROPOSAL + ACK is
mandatory, not optional. The acting agent must name what, why, and
rollback plan.

Format: `PROPOSAL: [what, why, rollback]`

Examples of gated actions: sending external messages, firewall
changes, package installs, force pushes, deleting shared resources.

Read-only research and local edits are exempt.

*Why:* During the Diamandis email, both agents prepared to send
independently. For irreversible actions, "ready to send" is not the
same as "I'm the one who sends." The trigger pull needs an explicit
gate, separate from the prep work.

### 8. Bind to localhost, not the world

Never bind a service to 0.0.0.0. Use 127.0.0.1 (or ::1) unless the
human lead explicitly approves a wider bind. This applies to dev
servers, test fixtures, dashboards — anything that listens on a port.

*Why:* 0.0.0.0 exposes the service to the entire network. On shared
machines with multiple agents, that's an unnecessary attack surface.
Localhost-only is the safe default.

## Task Ownership

When you claim a task, post it explicitly:

> **PROPOSAL:** AgentA will [task description]. Rollback: [plan].

When you ACK someone's proposal:

> **ACK** — AgentA owns [task]. I'll review.

The active task board lives in comms, not in this file. This file
defines the protocol; comms holds the state.

## Interrupt Protocol

The human lead's problem: no way to pause an agent mid-action. An agent in a
long tool call (hashcat, nmap, large git operation) is deaf until the
call finishes.

**Rules for agents:**
- Keep individual tool calls short. No single command should run longer
  than 10 minutes unattended.
- For long-running tasks, use background processes and check comms
  between each step.
- After every tool call that takes more than 30 seconds, check comms
  before the next one.

**Rules for the human lead:**
- Post PAUSE on the relevant channel. The agent will see it at the
  next comms check.
- Accept that turns are atomic — an agent can't stop mid-sentence.
  The minimum interrupt latency is one tool call.

**What PAUSE means:**
- Stop what you're doing after the current tool call completes.
- Post your current state to comms.
- Wait for further instructions. Don't resume until the human lead says GO.

## Communication

- Reply on the channel where the message was sent.
- Use replies (quote blocks) when responding to specific messages.
- Keep messages concise. Wall-of-text messages get skimmed.
- When proposing, state: what you'll do, why, and what you need from
  the team.
- When reporting, state: what you did, what the result was, what's
  next.

## The Loop Method

A method for overnight autonomous work. Generic task framing, repeated
cycles, no pre-planning.

**The cycle (one iteration):**

1. FIND one thing — Agent discovers the target, not human
2. DO it — Implement the change
3. VERIFY — Run ALL tests, not just new ones
4. FIX any failures — Before committing, never after
5. COMMIT clean — One clean commit per cycle
6. REPORT — Post completion to comms with specifics
7. REPEAT — Next cycle starts fresh

**What the human lead provides (once):**

- **Scope:** What repo/codebase to work on
- **Task type:** "refactor" / "test" / "implement" / "probe"
- **Count:** How many cycles
- **Constraints:** e.g. "DO NOT commit broken tests"
- **Reporting channel:** Where to post completions

**What the human lead does NOT provide:**

- Specific targets (agent finds them each cycle)
- Implementation details (agent decides approach)
- Review per cycle (pre-approved by tasklog)
- Ordering (agent picks what's most impactful)

**Why it works:**

- Generic tasks force discovery — the agent reads the code each cycle
- Test gate prevents drift — ALL tests every cycle, never more than one commit from green
- Comms reporting creates accountability — the log exists even if nobody reads it live
- One-at-a-time prevents half-done work — finish completely before starting next

**Anti-patterns:**

- Pre-planning all targets at cycle 1 (stale by cycle 5)
- Pre-exploring the codebase before the loop starts
- Batching commits (harder to revert)
- Skipping the test gate
- Not reporting until the end
- Grouping by type (all features, then all tests) — interleave instead

### The Tasklog

Before starting a loop, create a tasklog file in your repo's `loops/`
directory. This file IS the loop — each cycle's task is written out
verbatim so it survives compaction and can be fed as a prompt.

**File location:** `<your-repo>/loops/tasklog-<agent>-<name>.md`

**Structure:**

```markdown
# Tasklog: <Agent> <Name> — <scope>

**Date:** YYYY-MM-DD
**Scope:** <repo name>
**Protocol:** Loop Method — discover target each cycle, no pre-planning
**Report to:** #<channel>
**Test count start:** <N>

## Loop 1 — <Type>
<Verbatim task text. The full instruction for this cycle.>

**Status:**
**Approach:**
**Result:**

## Loop 2 — <Type>
<Same or different verbatim task text for this cycle.>

**Status:**
**Approach:**
**Result:**

(... one section per cycle ...)
```

**Key rules:**

- The task text is written in full in every loop section. Not a
  reference, not a header — the actual words the agent reads each cycle.
- Status/Approach/Result start empty. The agent fills them in after
  completing each cycle.
- When mixing task types (feature/refactor/test), interleave them
  (1-Feature, 2-Refactor, 3-Test, 4-Feature, ...) instead of grouping.
- The tasklog lives in the agent's own repo, not the target repo.
- Get ACK on the tasklog before starting. The tasklog IS the approval.

### Worked Example: Day 15 Feature Loop

**Task wording (repeated 5 times):**

> "With all you know about tomorrows plans about new agents and channels,
> find a single feature you think would be great. Implement the feature
> and the tests."

**Results (5 cycles, ~12 minutes):** Channel descriptions, enhanced
whoami, system join messages, auto sender colors, creation dialog
descriptions. 194→213 tests, zero regressions.

**Anti-pattern caught:** AgentA pre-planned all 5 features. the human lead corrected:
"Don't plan ahead. The whole idea is that it's generic."

### Worked Example: Day 13 Overnight Refactor+Test

**Task wording (repeated 10+10 times):** "Find 1 thing to refactor" and
"Find 1 test to write."

**Results (20 cycles each, ~2 hours):** AgentA: 92→186 tests, 10
refactorings, 5 crash bug fixes. an agent: 37→103 tests, 10 refactorings.
Zero regressions across both.

## Tool Safety

- Never use WebSearch or WebFetch inside subagents (Task tool). These
  tools have no reliable timeout — a hanging web request blocks the
  entire agent indefinitely.
- For web research in subagents, use `timeout 30 curl -sL <url>` in
  Bash instead. Fails predictably after 30 seconds.
- WebSearch/WebFetch are fine in the main agent context (daemon can be
  killed externally if stuck).

*Why:* Both agents got stuck simultaneously during the Diamandis OSINT
challenge (Feb 15). AgentA's subagent hung on WebSearch for 70 minutes,
blocking the entire agent. an agent also got stuck on web fetches. Neither
could be interrupted until the human lead noticed and called for a manual kill.

## Meta-Rule

Agents before processes. If following a rule makes the team slower
without making it better, change the rule. But change it explicitly —
propose the change on comms, get the human lead's ACK, then update this file.

This file changes rarely. It's not a log or a scratchpad. Changes
require the human lead's approval.
