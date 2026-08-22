# Releasing

How Jelly Shark is versioned, named, and tagged. The decisions here were settled in [#87](https://github.com/axeslasher/Jelly-Shark/issues/87); this file is where they live once that issue closes.

## Versioning

**Semantic versioning. The app stays on `0.y.z` until the first build reaches an external tester.**

That follows semver §4 — *"Major version zero (0.y.z) is for initial development. Anything MAY change at any time"* — and §5's guidance that `1.0.0` is for software in production. Nothing here is in production: no releases, no users, no external installs. So `1.0.0` is the version that ships to the first tester, not a reward for accumulated work. Staying in `0.x` is an accurate statement about the project, not modesty.

Within `0.x`:

- **MINOR** (`0.12.0`) — anything user-visible: a feature, a redesign, a platform, a subsystem replaced.
- **PATCH** (`0.12.1`) — fixes to a release that has already been tagged.

The first ten `0.x` releases were reconstructed from real merge chronology rather than estimated, and tagged retroactively; `v0.11.0` onward are tagged as they ship. `git tag -n1` is the authoritative record:

```
$ git tag -n1
v0.1.0    v0.1.0 — Chaney
...
v0.10.0   v0.10.0 — Steele
```

## The release name

Every MINOR release carries a name alongside its number. Patch releases are unnamed.

- **Before 1.0 — a star surname alone**, from the pre-auteur era: the Universal and Hammer monster performers, ordered by genre debut. That is thematically exact — `0.x` is the monsters, and the director era opens at `1.0`, when the compatibility promise starts.
- **From 1.0 — a horror director surname for the MAJOR**, and a star surname from that director's filmography for the MINOR.

### The rules

1. **The pair must have actually collaborated.** This is what makes the scheme work: each name is a verifiable fact rather than a pick, so there is nothing to bikeshed. It also disambiguates surname collisions on its own — `Raimi Campbell` is Bruce, `Craven Campbell` is Neve.
2. **Order is fixed up front, so there is no per-release decision.** For `1.x` and beyond that means ascending by first collaboration year, ties broken by billing. `0.x` is ordered by *era* instead — see the boxes below.
3. **Names are decoration, not a cap.** Ensemble sizes vary wildly by director. If a major outlives its name pool, the extra minors are simply unnamed. Do not stretch to a bad name, and do not let the pool dictate when to bump MAJOR.
4. **Don't match the director to the content of the release.** A major version's lifespan is unpredictable, so fix the order in advance and let meaning accrete retroactively.

### The pools

**`0.x` — classic horror performers, boxed by era.** A performer's box is fixed by their **first credited genre role** — the production it appears in picks the box, and the box's period orders it.

*Credited* is load-bearing. Carradine's first horror appearance is an uncredited walk-on as a hunter in *Bride of Frankenstein* (1935), which would file him beside Karloff a decade off the work anyone knows him for. *The production picks the box* is load-bearing too, because boxes overlap in time: Steele debuts in 1960, inside both Hammer's first wave and the AIP cycle, and *Black Sunday* is neither — it is Bava, and it is Italian.

| # | Box | Span | Used | Available |
|---|---|---|---|---|
| 1 | Silent & Expressionist | 1920–29 | Chaney | Veidt, Schreck, Wegener, Krauss |
| 2 | Universal Gothic | 1931–39 | Lugosi, Karloff, Rains, Lanchester | Clive, Frye, Atwill, Rathbone, Hobson, Holden |
| 3 | Universal 40s | 1940–48 | Price | Chaney Jr., Ankers, Carradine |
| 4 | Val Lewton / RKO | 1942–46 | — | Simon, Conway, Russell |
| 5 | Atomic age | 1949–56 | — | Court, Adams, Browning, Tobey |
| 6 | Hammer, first wave | 1955–66 | Cushing, Lee, Gough | Ripper, Shelley, Keir, Matthews |
| 7 | AIP Poe cycle | 1960–65 | — | Damon, Miller, Paget |
| 8 | Italian gothic | 1960–66 | Steele | Lavi |
| 9 | Hammer permissive | 1968–74 | Pitt | Bates, Carlson, Munro, Beswick, O'Mara |
| 10 | American independent | 1968–74 | — | Jones, O'Dea, Burns, Hansen |

**Boxes are movements, not disjoint time slices.** Several run concurrently — Lewton and Universal were making opposite kinds of horror in the same years, and that contemporaneity is the point of separating them. The `#` column is the walk order: start year ascending, with the two ties (7/8 at 1960, 9/10 at 1968) fixed here once so there is no tiebreak rule to apply later.

**Releases walk the boxes, reversing direction at each end.** Within a lap the box number moves monotonically. Boxes may be skipped, and one box may take consecutive releases — including at a turn, where it takes two by construction.

Both laps satisfy that as written:

- **Ascent, `v0.1.0`–`v0.11.0`:** 1, 2, 2, 2, 2, 3, 6, 6, 6, 8, 9
- **Descent, `v0.12.0`–`v0.16.0`:** 9, 6, 3, 2, 2

Lap 3 climbs again from box 2. Extend the queue between releases, never during one.

**Lap 2 is queued through `v0.16.0`:**

| Version | Name | Box | Debut |
|---|---|---|---|
| `v0.12.0` | Bates (Ralph) | 9 — Hammer permissive | *Taste the Blood of Dracula*, 1970 |
| `v0.13.0` | Ripper (Michael) | 6 — Hammer, first wave | *X the Unknown*, 1956 |
| `v0.14.0` | Chaney Jr. (Lon) | 3 — Universal 40s | *Man Made Monster*, 1941 |
| `v0.15.0` | Clive (Colin) | 2 — Universal Gothic | *Frankenstein*, 1931 |
| `v0.16.0` | Frye (Dwight) | 2 — Universal Gothic, the turn | *Dracula*, 1931 |

**Verify a name when you queue it, not when you shelf it.** Every name in the Used and queued columns has been checked against a source; the Available column has not, beyond the four that were checked because they moved a box boundary — Rathbone (1939, which is why box 2 runs to 1939 rather than 1936), Court (1952, which no box held before box 5 existed), Carradine (credited 1940s, not the 1935 walk-on) and Ripper (1956, which is why box 6 opens at 1955). Boxing turned the pool from a queue into a bench, and a bench entry is a candidate, not a commitment.

Two known snags on the bench, recorded so they are not rediscovered: **Carlson collides** — Richard (box 5) and Veronica (box 9) cannot both take the bare surname, and only Veronica is listed above. **Boxes 7 and 8 are thin**, because debut assignment works against them: Price, Rathbone, Lorre and Steele all did their defining AIP and Italian work long after debuting elsewhere, so those boxes hold only performers who genuinely started there.

**Lon Chaney Jr. is written `Chaney Jr.`** — `v0.1.0` spent the bare surname on his father, and `0.x` has no director pairing to disambiguate the way rule 1 does for `1.x`.

**`1.x` — Carpenter.** 1.0 Curtis (*Halloween*, 1978) → 1.1 Pleasence (*Halloween*, 1978) → 1.2 Barbeau (*The Fog*, 1980) → 1.3 Russell (*Escape from New York*, 1981) → 1.4 Piper (*They Live*, 1988).

`2.x` and beyond are unchosen. Pick the director when `2.0` is in sight, not before — rule 4 means there is nothing to gain from deciding early.

### Where the name is recorded

Not in `MARKETING_VERSION` — App Store Connect requires one to three period-separated integers there. The name lives in:

- **The annotated tag** — `git tag -a v1.3.0 -m "v1.3.0 — Carpenter Russell"`
- **The GitHub Release title** — `v1.3.0 — Carpenter Russell`
- **The About screen** — currently an inert row ([#157](https://github.com/axeslasher/Jelly-Shark/issues/157)), and the only place a user would ever see it

## What must move together

The tag and the app's version are two records of the same fact, and nothing enforces that they agree:

| Record | Where | Set by |
|---|---|---|
| Marketing version | `MARKETING_VERSION` in `Jelly Shark.xcodeproj/project.pbxproj` | Edited by hand, two occurrences (app target Debug + Release) |
| Tag | `refs/tags/v*` | `git tag` at release time |

If they drift, the app reports a version that no tag corresponds to. Bump the first, then tag — in that order, for the reason below.

The two **test** targets sit at `MARKETING_VERSION = 1.0`, which is Xcode's template default. They don't ship. Leave them; they are not evidence of an inconsistency.

## Cutting a release

`main` takes no direct pushes and `enforce_admins` is on, so a release starts with a PR like anything else. Never use `gh pr merge --admin` to shortcut this.

1. **Branch** off current `main`.
2. **Bump `MARKETING_VERSION`** in `project.pbxproj` — both app-target configurations.
3. **Verify** with `make format`, then `make test` (the pre-merge tier; see the Makefile).
4. **Commit and push.** Commits are signed; tags are not — see Tag signing and protection.
5. **Open the PR and merge it** once CI is green.
6. **Pull `main`, then tag the merge commit** — not the branch tip.
7. **Create the GitHub Release** from that tag, titled `v0.12.0 — <name>`.

Steps 6 and 7 in full:

```bash
git checkout main && git pull
git tag -a v0.12.0 -m "v0.12.0 — <name>" -m "<what shipped, one paragraph>"
git push origin v0.12.0
gh release create v0.12.0 --title "v0.12.0 — <name>" --notes "<same summary>"
```

**Step 6 is the order-dependent one.** Tagging before the merge points the tag at a commit that is not on `main`, and a squash or rebase leaves the tag dangling on an orphaned object. Tag after merging, on the commit that actually landed. A pushed tag cannot be corrected in place: the ruleset below blocks deletion and force-push, so fixing one means disabling that ruleset first. Get the target right before pushing.

**Pushing the tag also triggers the upload.** `.github/workflows/release.yml` archives both platforms from the tagged commit and uploads them to App Store Connect (TestFlight), after checking that the tag matches `MARKETING_VERSION` — a mismatched tag fails the run instead of shipping a mislabeled build. It signs via xcodebuild cloud signing with an App Store Connect API key; the required secrets and variables are listed at the top of the workflow file. Never rename that file — the build-number hazard below is scoped to it.

## Build numbers

`CURRENT_PROJECT_VERSION` stays at `1` in `project.pbxproj` — that is the local-developer default, and nothing about local builds should change. The release invocation overrides it on the command line, which `xcodebuild` accepts directly:

```
CURRENT_PROJECT_VERSION = ${{ github.run_number }}.${{ github.run_attempt }}
```

`CFBundleVersion` accepts up to three period-separated integers, and App Store Connect orders them as a dotted version, so `41.1 < 42.1 < 42.2 < 43.1` — unique per attempt and monotonic. App Store Connect rejects any upload that reuses a `(marketing version, build number)` pair.

**The attempt half is load-bearing.** GitHub documents that `run_number` *"does not change if you re-run the workflow run"* — only `run_attempt` increments. Without it, re-running a failed release workflow reproduces the same build number, which is exactly the duplicate that gets rejected, at exactly the moment you need the re-run to work.

**One hazard:** `run_number` is scoped to a *workflow file* and restarts at 1 if that file is renamed or recreated. Build numbers only need to increase within a given marketing version, so either never rename the release workflow, or bump `MARKETING_VERSION` in the same change that recreates it.

## Declarations App Store Connect and App Review will ask for

Both are answered in the app's partial `Info.plist` (`Jelly Shark/Info.plist`), which Xcode merges with the generated one. Nothing here needs re-answering per build — but Review asks about the second one in prose, so the justification is recorded here rather than only in the ticket that added it ([#273](https://github.com/axeslasher/Jelly-Shark/issues/273)).

**Export compliance** — `ITSAppUsesNonExemptEncryption = false`. The app ships no encryption of its own; all TLS is the OS's. Without the key declared, every upload sits in a "Missing Compliance" hold until it is answered by hand in App Store Connect.

**Arbitrary loads** — `NSAppTransportSecurity` → `NSAllowsArbitraryLoads = true`. If Review asks why ATS is disabled, the answer is:

> The app connects only to a Jellyfin media server that the user configures themselves, typically on their own private network. Self-hosted servers are commonly reached over plain HTTP — behind a TLS-less reverse proxy, at a DDNS name, or on a tailnet hostname — and the app has no way to know or constrain that address at build time, so no per-domain exception can be enumerated. `NSAllowsLocalNetworking` does not cover a qualified hostname, which is the shape that fails.

## The `v*` tag namespace is reserved

Anything that reads a version out of git must match explicitly:

```bash
git describe --tags --match 'v*'
```

`git describe` resolves against the nearest reachable tag *of any name*. The three SPM packages live in this repo as path dependencies and have no versions today — but if `DesignSystem` is ever published ([#210](https://github.com/axeslasher/Jelly-Shark/issues/210)) it needs its own tag line, conventionally scoped (`DesignSystem-1.2.0`), and those tags land on *these* commits. An unscoped `git describe` would then report a package version wherever the app version is shown or stamped: the About screen, a release build, a CI artifact name. It fails silently and produces a plausible-looking number.

## Tag signing and protection

**Tags are not signed.** Commits are (`commit.gpgsign = true`, `gpg.format = ssh`, via 1Password's `op-ssh-sign`), so the *content* of a release is already attested. A tag signature would attest something else — "this commit is v0.11.0" — and nothing in this project verifies that claim: no consumer resolves the repo by tag, and the signature users actually depend on is Apple's on the shipped binary. `op-ssh-sign` also only works from a machine with 1Password, so signing tags would commit the project to tagging by hand forever, or to provisioning a second key into Actions if archive-and-upload is ever automated.

**A ruleset protects the tag namespace instead** — [Release tags](https://github.com/axeslasher/Jelly-Shark/rules/20971397), `enforcement: active`, no bypass actors:

| | |
|---|---|
| Covers | `refs/tags/v*`, `refs/tags/JellyfinKit-*`, `refs/tags/DesignSystem-*`, `refs/tags/Features-*` |
| Blocks | `deletion`, `non_fast_forward` |

That addresses the threat a signature would only have made *detectable* — a stolen write token re-pointing a release tag at an older commit — by refusing the push outright. Both rules were verified against the live remote when the ruleset was created: `git push origin :refs/tags/v0.11.0` and a force-move both came back `GH013`.

The trade is that a mistyped tag is unfixable until the ruleset is disabled. That is deliberate. The package namespaces are covered ahead of any package actually being published ([#210](https://github.com/axeslasher/Jelly-Shark/issues/210)) so publishing one never needs a second ruleset.

## Open decisions

- **A `CHANGELOG.md`.** None exists. The tag annotations and GitHub Release bodies currently carry that content.

## Note: what can and cannot be backfilled

- **Git tags are fully retroactive.** A tag can point at any historical commit, and an annotated tag's date can be set with `GIT_COMMITTER_DATE`, so `git log --decorate` and `git describe` read naturally.
- **GitHub Releases are not.** The create and update endpoints accept `tag_name`, `target_commitish`, `name`, `body`, `draft`, `prerelease`, `make_latest` and friends — and no date field. A backfilled Release reads "released now" regardless of where its tag points. That is why the ten historic versions are tags without Releases. `v0.11.0` is the first with one.
