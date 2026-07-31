# Releasing

How Jelly Shark is versioned, named, and tagged. The decisions here were settled in [#87](https://github.com/axeslasher/Jelly-Shark/issues/87); this file is where they live once that issue closes.

## Versioning

**Semantic versioning. The app stays on `0.y.z` until the first build reaches an external tester.**

That follows semver §4 — *"Major version zero (0.y.z) is for initial development. Anything MAY change at any time"* — and §5's guidance that `1.0.0` is for software in production. Nothing here is in production: no releases, no users, no external installs. So `1.0.0` is the version that ships to the first tester, not a reward for accumulated work. Staying in `0.x` is an accurate statement about the project, not modesty.

Within `0.x`:

- **MINOR** (`0.11.0`) — anything user-visible: a feature, a redesign, a platform, a subsystem replaced.
- **PATCH** (`0.11.1`) — fixes to a release that has already been tagged.

The ten `0.x` releases were reconstructed from real merge chronology rather than estimated, and tagged retroactively. `git tag -n1` is the authoritative record:

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
2. **Order within a major is ascending by first collaboration year**, ties broken by billing. Fixed up front, so there is no per-release decision.
3. **Names are decoration, not a cap.** Ensemble sizes vary wildly by director. If a major outlives its name pool, the extra minors are simply unnamed. Do not stretch to a bad name, and do not let the pool dictate when to bump MAJOR.
4. **Don't match the director to the content of the release.** A major version's lifespan is unpredictable, so fix the order in advance and let meaning accrete retroactively.

### The pools

**`0.x` — classic horror stars, by genre debut.** Used: Chaney (1923), Lugosi (Feb 1931), Karloff (Nov 1931), Rains (1933), Lanchester (1935), Price (1940), Cushing (1957), Lee (1957), Gough (1958), Steele (1960).

**Next: `v0.11.0` — Pitt** (1970).

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
4. **Commit and push.** Commits are signed — see Open decisions for the tag-signing question.
5. **Open the PR and merge it** once CI is green.
6. **Pull `main`, then tag the merge commit** — not the branch tip.
7. **Create the GitHub Release** from that tag, titled `v0.11.0 — Pitt`.

Steps 6 and 7 in full:

```bash
git checkout main && git pull
git tag -a v0.11.0 -m "v0.11.0 — Pitt" -m "<what shipped, one paragraph>"
git push origin v0.11.0
gh release create v0.11.0 --title "v0.11.0 — Pitt" --notes "<same summary>"
```

**Step 6 is the order-dependent one.** Tagging before the merge points the tag at a commit that is not on `main`, and a squash or rebase leaves the tag dangling on an orphaned object. Tag after merging, on the commit that actually landed. Fixing a pushed tag means deleting the remote ref, retagging, and force-pushing — and anyone who fetched in between keeps the stale one.

## Build numbers

`CURRENT_PROJECT_VERSION` stays at `1` in `project.pbxproj` — that is the local-developer default, and nothing about local builds should change. The release invocation overrides it on the command line, which `xcodebuild` accepts directly:

```
CURRENT_PROJECT_VERSION = ${{ github.run_number }}.${{ github.run_attempt }}
```

`CFBundleVersion` accepts up to three period-separated integers, and App Store Connect orders them as a dotted version, so `41.1 < 42.1 < 42.2 < 43.1` — unique per attempt and monotonic. App Store Connect rejects any upload that reuses a `(marketing version, build number)` pair.

**The attempt half is load-bearing.** GitHub documents that `run_number` *"does not change if you re-run the workflow run"* — only `run_attempt` increments. Without it, re-running a failed release workflow reproduces the same build number, which is exactly the duplicate that gets rejected, at exactly the moment you need the re-run to work.

**One hazard:** `run_number` is scoped to a *workflow file* and restarts at 1 if that file is renamed or recreated. Build numbers only need to increase within a given marketing version, so either never rename the release workflow, or bump `MARKETING_VERSION` in the same change that recreates it.

## The `v*` tag namespace is reserved

Anything that reads a version out of git must match explicitly:

```bash
git describe --tags --match 'v*'
```

`git describe` resolves against the nearest reachable tag *of any name*. The three SPM packages live in this repo as path dependencies and have no versions today — but if `DesignSystem` is ever published ([#210](https://github.com/axeslasher/Jelly-Shark/issues/210)) it needs its own tag line, conventionally scoped (`DesignSystem-1.2.0`), and those tags land on *these* commits. An unscoped `git describe` would then report a package version wherever the app version is shown or stamped: the About screen, a release build, a CI artifact name. It fails silently and produces a plausible-looking number.

## Open decisions

- **Tag signing.** Every commit in this repo is signed (`commit.gpgsign = true`, `gpg.format = ssh`, via 1Password's `op-ssh-sign`), but `tag.gpgsign` is unset and all ten existing tags are annotated-only. Either sign tags going forward and accept that the backfilled ten are unsigned, or leave tags unsigned for consistency with them. Not yet decided.
- **Archive and upload: manual or automated?** There is no release workflow today — `.github/workflows/` has only `swiftformat.yml` and `tests.yml`. The build-number expression above is the same either way.
- **A `CHANGELOG.md`.** None exists. The tag annotations and GitHub Release bodies currently carry that content.

## Note: what can and cannot be backfilled

- **Git tags are fully retroactive.** A tag can point at any historical commit, and an annotated tag's date can be set with `GIT_COMMITTER_DATE`, so `git log --decorate` and `git describe` read naturally.
- **GitHub Releases are not.** The create and update endpoints accept `tag_name`, `target_commitish`, `name`, `body`, `draft`, `prerelease`, `make_latest` and friends — and no date field. A backfilled Release reads "released now" regardless of where its tag points. That is why the ten historic versions are tags without Releases.
