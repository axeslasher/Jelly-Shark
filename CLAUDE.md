# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Jelly Shark is a premium Jellyfin client for tvOS and visionOS that elevates the media browsing and playback experience through exceptional UI design and deep customization. Unlike existing Jellyfin clients, it treats the interface as a feature with genre-inspired theming and extensive component customization.

**Key Differentiators**:
- Genre-inspired theming system (Standard, Horror, Action, Video Store)
- Component variants with depth (different layouts work within any theme)
- Platform-native excellence (tvOS focus engine, visionOS spatial layouts)
- Professional 10-foot UI design for lean-back viewing
- Open source, community-driven (MIT)

**Target Platforms**:
- Apple TV 4K (tvOS 26.0+)
- Apple Vision Pro (visionOS 26.2+)

## Working Agreements

These bind every session and every subagent — a subagent inherits this file and nothing
else. Where they collide with convenience, they win.

### Evidence before assertion

- Label every conclusion **verified** (and cite what verifies it) or **hypothesis
  (unverified)**. A hypothesis never lands in a doc, issue body, PR description, commit
  message, or memory file as settled fact.
- "Semantically inert", "no-op", "should be safe" are claims, not observations. Cite the
  build, test, or device evidence, or say plainly that it wasn't checked.
- A suite is green when the **exit code** says so. Never report a result read off a grepped
  summary line. Never report device behaviour from a console session you didn't open in this
  run — check the run timestamp and device name first.
- **Device evidence outranks a green suite.** If a device-verified fix fails a test, the
  harness is wrong; fix the harness, not the fix.
- Probe instrumentation, scratch scripts, and spike scaffolding stay in place until the
  findings are written up and merged. Don't tidy them away early.

See § What tests cannot verify: appearance and tvOS focus behaviour aren't verifiable by any
suite here, and asserting them from a passing build is the same error.

### Plan gate

Before writing code for anything touching more than one file, post this and wait:

1. The smallest change that satisfies the acceptance criteria.
2. What previously-merged work it could regress, and why it won't.
3. The file footprint.
4. How it gets verified, and in which venue — host suite, simulator suite, or device.
5. Anything removed, rebuilt, or renamed that wouldn't be expected.

Never start version-bump, release, or tag work unasked; release timing is a product call.
When offering options, say up front which ones regress existing behaviour. Run plans and
multi-step procedures go in numbered lists or tables, never prose paragraphs.

### Writing

Everything written for a person to read — commit messages, PR bodies, issue bodies, docs,
and code comments — follows the same shape. This binds subagents too.

- **Lead with the outcome or the action.** The first line says what changed, or what to do.
  Context comes after, if it earns its place.
- **Numbered lists and tables for anything with steps.** Never a procedure buried in a
  paragraph. Cap a list at five items; past five, split into must / nice-to-have.
- **Plain words.** No jargon where a common word works; expand an acronym on first use.
  Short paragraphs, three sentences at most.
- **Current state only.** Delete superseded text rather than layering a correction on top of
  it. One short history note at most, and only when the history changes what to do next.
- **Never append a session link.** No `Claude-Session:` trailer, no `claude.ai` URL in a
  commit, PR, or issue. They are not useful to come back to.

Code comments say *why*, not *what*, and match the density of the code around them.

A PR body answers three things and stops: what changed, how it was verified, and UAT
Device Verification. An issue body answers: the decision, the evidence, the acceptance
criteria.

### Working with agents

- **One reviewer per diff.** A single Opus agent reviews a branch or PR. Never fan out
  parallel reviewers over the same files — that has twice hit the rate limit and spent a
  large share of session budget in minutes without adding findings.
- **Parallel implementers get worktrees.** Agents sharing the checkout collide. Fence each to
  its own worktree and a non-overlapping file footprint, and check the footprints don't
  overlap before launching.
- **Stop review agents before editing the working tree.** They scope from the tree, so a
  mid-flight edit invalidates their findings: stop, edit, re-spawn.
- State the fencing — which issue and which files each agent owns — before spawning anything.

## Building & Running

### Run Tests

The app ships only to tvOS/visionOS, so tests run in two venues. Both run in CI
on every PR (`.github/workflows/tests.yml`), so nothing is silently skipped
without anyone noticing.

**Use the cheapest tier that can fail on your change** (warm timings, measured
2026-07-25; cold, the simulator tiers cost minutes):

```bash
make test-host                        # ~5s  — JellyfinKit only, no simulator. The inner-loop tier.
make test-only ONLY=DesignSystemTests # ~23s — one simulator suite (also: FeaturesTests, "Jelly SharkTests")
make test                             # ~43s — both venues, everything. Pre-merge / CI only.
make test-sim                         # the simulator venue on its own
```

**Do not run `make test` mid-iteration.** CI owns the full suite; locally it is
a pre-merge check, not an iteration step.

Why the split: `DesignSystem` and `Features` reference tvOS/visionOS-only SwiftUI
APIs and no longer compile for the Mac host, so their test targets are wired into
the `Jelly Shark` scheme and run on the simulator. `JellyfinKit` is pure logic,
but its `KeychainStore`/`SessionStore` tests need a real keychain (unavailable to
a host-less simulator test bundle), so it runs on the host via `swift test`.

### What tests cannot verify

Visual appearance and tvOS focus behavior are invisible to every suite in this
repo. Do not write probe tests, print-based measurement harnesses, key-event
robots, or simulator UI automation to check them — each has cost a session and
none has worked. To measure a threshold, bisect the constant and read pass/fail.
To verify appearance or focus, build and ask for a device check.

Any change to scrolling, opacity/fades, snapping, layout offsets, `.disabled`,
or navigation state must state which elements remain focusable and where default
focus lands — that regression class ships silently otherwise.

### Formatting

The codebase is formatted with SwiftFormat, pinned to **0.62.1** (`brew install swiftformat`; the Makefile refuses other versions so local runs match CI). Config lives in `.swiftformat` — SwiftFormat defaults plus `--swiftversion 6.2`, with three rules disabled because they change semantics rather than formatting: `redundantSelf`, `swiftTestingTestCaseNames`, and `noForceUnwrapInTests` (each documented with its reason in the config file).

```bash
make format        # format all Swift sources in place
make lint          # check only — what CI and the pre-commit hook run
make install-hooks # one-time opt-in: enables the lint-only pre-commit hook (.githooks/)
```

**Always run `make format` after modifying Swift code and before finishing a change.** A GitHub Actions check (`.github/workflows/swiftformat.yml`) runs `swiftformat --lint` on every PR with the same pinned version, so unformatted code fails CI.

## Swift & SwiftUI conventions

Modern-API rules the formatter can't enforce. The tree currently has zero violations of
the first two groups — keep it that way rather than cleaning up later.

**Data flow and concurrency**

1. Shared state is an `@Observable` class, owned with `@State`, passed with `@Bindable` or
   `@Environment`. Never `ObservableObject`, `@Published`, `@StateObject`,
   `@ObservedObject`, or `@EnvironmentObject`.
2. Mark every `@Observable` class `@MainActor`.
3. Prefer `async`/`await` to closure-based variants wherever both exist. No
   `DispatchQueue.main.async`.
4. No force unwraps or force `try` outside tests and genuinely unrecoverable paths.

**SwiftUI API choices**

1. `foregroundStyle()`, not `foregroundColor()`. `clipShape(.rect(cornerRadius:))`, not
   `cornerRadius()`.
2. `Tab`, not `tabItem()`. `NavigationStack` + `navigationDestination(for:)`, not
   `NavigationView`.
3. `Task.sleep(for:)`, not `Task.sleep(nanoseconds:)`.
4. `Button` over `onTapGesture()` unless the tap's location or count is actually needed.
   An image-only button always carries text — `Button("Play", systemImage: "play.fill")`
   — which is also how it gets a VoiceOver label.
5. `FormatStyle` for user-facing numbers and dates, never `DateFormatter`,
   `NumberFormatter`, or `String(format:)`.

**Deliberate exceptions — do not "modernize" these**

| Pattern | Why it stays |
| --- | --- |
| `String(format:)` in HLS playlists and `S%02dE%02d` IDs | Protocol text and identifiers, not user-facing numbers. `FormatStyle` is the wrong tool. |
| `DispatchQueue` in the playback servers and discovery socket | Network.framework listeners take a queue. Not a concurrency choice. |
| `AnyView` in `UpNextProposalViewController` | `UIHostingController` bridge. Required. |
| UIKit in playback | `AVPlayerViewController` owns its own `UIWindow`; the player layer is UIKit by necessity. |
| `ScrollViewReader`, `GeometryReader`, `onGeometryChange` | Device-verified scroll and focus behaviour depends on them. See § What tests cannot verify before changing them. |

## Xcode MCP

When the Xcode MCP is available, prefer its tools to generic equivalents:

| Tool | Use for |
| --- | --- |
| `DocumentationSearch` | Confirm an API exists and is available on tvOS/visionOS 26 before writing against it. |
| `BuildProject` / `GetBuildLog` | Build and read errors after a change. |
| `RenderPreview` | Render the five-theme `#Preview` tabs. Still not proof of appearance — see § What tests cannot verify. |
| `XcodeRead`, `XcodeWrite`, `XcodeUpdate` | Editing files Xcode has open, so the project file stays consistent. |

## Architecture

Three local SPM packages under `Packages/` (JellyfinKit, DesignSystem, Features) plus the
shared `Jelly Shark/` app target. Module contents, data flow, and the decision log live in
docs/ARCHITECTURE.md — read the source or that doc rather than a summary here, which rots.

## Jellyfin Integration

- Minimum supported Jellyfin server: **10.8.0+**.
- The server is the source of truth for all media, metadata, and user state. Local storage is
  cache and performance only — never authoritative.
- The access token, server URL, and user ID are persisted to the **Keychain** as a `SavedSession`
  — NEVER to UserDefaults. Don't cache auth tokens anywhere else, and don't cache video streams
  or transcoding decisions at all.

Endpoint coverage, the auth/restore flow, and the caching plan live in docs/JELLYFIN_INTEGRATION.md.

## Theming System

### Core Concept
Themes are **genre-inspired visual languages** that evoke the mood of different film genres. Each theme defines color, typography, motion, and spacing, while component variants define structure and layout.

**Themes** (high-level visual language):
- **Standard**: Elegant, timeless baseline (General Sans / Satoshi typography, neutral dark palette with an orange accent, smooth animations)
- **Horror**: Atmospheric dread (angular typography, blood reds/blacks, slower tension-building animations)
- **Action**: Kinetic energy (geometric technical sans-serifs, electric blues, high-speed animations)
- **Video Store**: 90s nostalgia (rounded friendly typography, Blockbuster blue/gold, playful animations)
- **Sci-Fi**: implemented alongside the four above

The genre palettes (Horror / Action / Video Store / Sci-Fi) are hand-curated, not placeholder
picks. Refining them further is deliberate design work Justin owns — never an opportunistic
fix, and never a drive-by "correction" to a shade that looks off in isolation.
`ThemeCatalogTests` (identity, distinctness, WCAG contrast) is the guardrail any future
curation must keep green.

**Component Variants** (structural flexibility, not yet built):
- Media cards: poster-dominant, landscape, minimal, detailed, immersive
- Detail page heroes: cinematic, minimal, split-screen, poster-first
- Navigation: tab bar, sidebar, immersive top menu
- List density: compact, comfortable, spacious

Users can switch themes globally and customize component variants individually, all without app restart.

## Important Design Decisions

### Platform Adaptations
What shares (90%+): API client, data models, business logic, design tokens, base components, auth flows

What diverges: Navigation patterns (TabView vs WindowGroup), input handling (remote vs hands/eyes), focus management (tvOS focus engine vs visionOS spatial), immersive layouts

Strategy: Keep components platform-agnostic, use `#if os(tvOS)` conditionals and protocol abstractions where needed

### Performance Targets
- <2s initial library load
- <500ms theme switching
- Smooth 60fps scrolling
- <100MB memory footprint (excluding media cache)

### Accessibility Requirements
All themes must maintain:
- WCAG AA contrast ratios minimum
- Dynamic Type support (scale with system settings)
- VoiceOver labels for all interactive elements
- Focus indicators that work in all themes (minimum 3:1 contrast)
- Reduce Motion support (disable complex animations)

## Development Guidelines

### When Adding New Features
- Reference the PRD (docs/PRD.md) for product requirements and success criteria
- Follow the architecture patterns in docs/ARCHITECTURE.md
- Apply theming principles from docs/DESIGN_SYSTEM.md for all UI components
- Every new visual component or screen ships with the five-theme `#Preview`
  tabs on a themed ground (`.previewCanvas` / the Features preview trait) —
  conventions and named exceptions in docs/DESIGN_SYSTEM.md § Previews
- Use Jellyfin API patterns documented in docs/JELLYFIN_INTEGRATION.md

### Avoid Over-Engineering
- Only make changes that are directly requested or clearly necessary
- Don't add features, refactor code, or make improvements beyond what was asked
- Keep solutions simple and focused
- Don't create helpers or abstractions for one-time operations

## Reference Documentation

Full documentation is available in the `/docs` directory:
- **PRD.md**: Product requirements, feature list, success criteria, marketing positioning
- **ARCHITECTURE.md**: Module structure, data flow, tech stack, decision log
- **DESIGN_SYSTEM.md**: Theming philosophy, color palettes, typography, component variants
- **JELLYFIN_INTEGRATION.md**: API endpoints, authentication, data models, caching strategy
- **PLAYBACK_MATRIX.md**: what each delivery path does to a given source — codec tags, HDR/DV signalling, audio passthrough, subtitles — measured against a live server, with verification markers and re-verification method
- **RELEASING.md**: Versioning scheme, release naming, how to cut and tag a release
- **FIGMA_TOKENS.md**: The Figma design file — variable collections mirroring the tokens, component↔code mapping, representation deviations, re-sync procedure

API Documentation: https://api.jellyfin.org
