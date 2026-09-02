# Spike: #<issue> — <one-line symptom>

<!--
Copy to docs/spikes/<issue-number>.md at the start of a root-cause investigation.
Rules, in force until the spike is closed:

- Nothing graduates to a doc, issue body, PR, or memory file until it is CONFIRMED here
  with cited evidence. Everything else stays labelled a hypothesis.
- An experiment must name the hypothesis it targets and the result that would falsify it.
  If no result could falsify it, it is not an experiment.
- The scaffolding inventory below is a do-not-delete list. It survives until the findings
  are merged and the spike is closed.
- Don't contaminate the evidence: tag and exclude traffic or logs this investigation
  generates itself.
- Update this file after every run, before reporting anything.
-->

**Status**: open | closed
**Issue**: <link>
**Started**: YYYY-MM-DD

## Symptom

What is observably wrong, how to reproduce it, and the raw evidence that it exists at all
(log excerpt, timing, frame diff, screenshot). Note the venue — host, simulator, device —
because the simulator lies in both directions.

## Hypothesis ledger

| ID | Hypothesis | Status | Falsifying experiment | Evidence |
|----|-----------|--------|----------------------|----------|
| H1 | | PROPOSED | | |
| H2 | | TESTING | | |
| H3 | | FALSIFIED | | E2 |
| H4 | | CONFIRMED | | E4 |

Status is one of PROPOSED, TESTING, FALSIFIED, CONFIRMED. Nothing reaches CONFIRMED without
an evidence row pointing at a specific experiment below.

## Experiments run

Append-only. Newest last.

### E1 — <what was changed or measured> (YYYY-MM-DD, venue)

- **Targets**: H1
- **Falsifies H1 if**: <the result that would kill it>
- **Method**: <the constant that was bisected, the build, the device run>
- **Raw output**:

```
<excerpt, with timestamps>
```

- **Result**: H1 → FALSIFIED / still TESTING

## Scaffolding

Do not remove any of this until the spike is closed.

| What | Where | Why it exists |
|------|-------|---------------|
| | | |

## Current best explanation

**Provisional until a CONFIRMED row exists.** What the evidence supports so far, and what it
does not yet rule out.

## Open questions

Things a fresh agent picking this up would need answered.
