---
name: issue
description: Take a GitHub issue from ticket to merged PR — scope gate, branch, implement, tiered verification, PR, branch cleanup. Use when asked to pick up, plan, or implement a numbered issue (e.g. "/issue 62", "implement #62", "pick a fun open issue and build it").
---

# Issue → PR

The standard delivery loop for this repo. `$ARGUMENTS` is the issue number, if given.

If no number was given, run `gh issue list --state open` and propose one, ranked
by what unblocks the most other work. Wait for a pick before step 1.

## 1. Read the whole ticket

`gh issue view $ARGUMENTS --comments`

Comments frequently contain the real acceptance criteria and revisions to the
original body. Read them.

## 2. Scope gate — STOP HERE

Post back, before touching any file:

- **Scope**: 2–3 bullets of what you will change.
- **Not touching**: the adjacent things you could be tempted to fix and won't.
- **Acceptance checklist**: functional requirements as testable bullets; every
  tvOS focus path that must still work; visual details that must not regress;
  exactly what Justin needs to check on device.
- **Open questions**, if any.

Then **wait for a go-ahead.** Do not start implementing. This gate is the whole
point of the skill: it is cheaper to correct scope in one message than to
correct it after a branch of edits.

## 3. Branch

```bash
git checkout main && git pull && git checkout -b <type>/<slug>
```

`<type>` is `feat`, `fix`, `perf`, or `chore` — match the recent history.

## 4. Implement

- Load the `swiftui-specialist` skill before writing SwiftUI.
- Match the surrounding code's idiom, comment density, and naming.
- No refactors, no "while I'm here" cleanups, no new abstractions for one-time
  operations. If you find something worth fixing, note it for step 8.

## 5. Verify — cheapest tier that can fail on this change

See the tier table at the top of the `Makefile`.

- `make test-host` (~5s) after edits to JellyfinKit logic.
- `make test-only ONLY=<target>` (~23s) for DesignSystem/Features changes.
- `make build` for anything that could break the tvOS build.
- `make format` before you call the change done. Non-negotiable — CI lints it.

**Never run `make test` mid-iteration.** CI runs both venues on every PR
(`.github/workflows/tests.yml`); the full local suite is a pre-merge check only.

**Do not** write probe tests, print-based measurement harnesses, key-event
robots, or simulator UI automation to verify visual or focus behavior. None of
them work on this codebase and each one has cost a session. To measure a
threshold, bisect the constant and read pass/fail. To verify appearance or
focus, build and ask Justin to look on device.

### Focus-engine check

If the change touched scrolling, opacity/fades, snapping, layout offsets,
`.disabled`, or navigation state, list in your summary which elements remain
focusable and where default focus lands on appear. This class of regression is
invisible to every test in the repo.

### Two-strike rule

If two attempts at the same bug have failed, **stop**. Do not attempt a third
blind fix. Summarize what's been ruled out, state the top remaining hypotheses
with the cheapest discriminating test for each, and hand back for a screen
recording or a direction call.

## 6. Commit

Split into clean logical commits — one concern each. Show `git diff --staged`
before writing the message if there's any ambiguity about what's included.

## 7. PR, then stop

```bash
gh pr create --fill   # link the issue in the body: "Closes #N"
```

Then **stop and ask Justin to verify on device.** Do not start the next thing,
chase a tangent, or open follow-up investigations before the PR exists.

## 8. After merge

```bash
git checkout main && git pull && git branch -d <slug> && git push origin --delete <slug>
```

File anything deferred from steps 4–5 as a new issue with repro steps,
acceptance criteria, and a size estimate — groomed, not a stub.

## Conventions

- To update an issue, `gh issue edit` the **body**. Only comment if asked to comment.
- Milestones are horror-movie names and are fun groupings, not versions or dates.
  Sequencing comes from Priority/Size on project board #4.
- Never remove an existing accessibility trait or modifier (`.isButton`, etc.)
  unless explicitly asked — several are placeholders for planned work.
