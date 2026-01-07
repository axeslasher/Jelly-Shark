# Product Requirements Document: Jelly Shark

## Concept

Jelly Shark is a premium Jellyfin client for tvOS and visionOS that elevates the media browsing and playback experience through exceptional UI design and deep user customization. Built by someone who designed TV interfaces for Starz, it brings professional-grade UX to the open-source media server ecosystem.

Unlike existing Jellyfin clients that treat the interface as functional but forgettable, Jelly Shark makes the UI itself a feature - beautiful, configurable, and tailored to how each user wants to experience their media library.

---

## Key Differentiators

### 1. Genre-Inspired Theming System
**What**: Themes based on film genres and media experiences, not arbitrary color schemes

**Why it matters**: Visual language should evoke the mood of what you're watching. Horror libraries deserve atmospheric dread, not corporate blue.

**Implementation**:
- Launch themes: Standard (elegant baseline), Horror (blood reds and tension), Action (kinetic energy), Video Store (Blockbuster nostalgia)
- Each theme has light and dark modes
- Distinct typography, color palettes, motion design, and mood per theme
- Runtime switching - no app restart required
- Component variants layer on top: users can customize layouts while staying within theme aesthetic

**Result**: Theming that tells a story and creates atmosphere, not just "pick your favorite color."

---

### 2. Component Variants with Depth
**What**: Every UI component has multiple layout and presentation variants that work within any theme

**Why it matters**: Different content types and user preferences demand different presentations. Variants provide structural flexibility while themes provide aesthetic consistency.

**How it works**:
- Themes define visual language (color, type, motion)
- Variants define structure (layout, density, information hierarchy)
- Users mix and match: Horror theme + Minimal card layout, or Standard theme + Detailed cards

**Examples**:
- Media cards: poster-dominant, landscape, minimal, detailed, immersive
- Detail page heroes: cinematic, minimal, split-screen, poster-first
- Navigation: tab bar, sidebar, immersive top menu
- List density: compact, comfortable, spacious

**User control**: Global theme selection with granular component customization where it matters.

---

### 3. Platform-Native Excellence
**What**: Doesn't just "run on" tvOS and visionOS - actually leverages each platform's unique capabilities

**tvOS**:
- Focus engine that feels precise and intentional
- Remote gestures that make sense
- Top Shelf integration for quick access
- Siri integration for voice control

**visionOS**:
- Spatial layouts that use depth meaningfully
- Immersive viewing modes for browsing
- Hand/eye tracking that feels natural
- Window management that respects user's space

**Why it matters**: Platform-specific optimizations make the app feel native, not like a web wrapper or lazy port.

---

### 4. Professional 10-Foot UI Design
**What**: Interface designed specifically for the lean-back, 10-foot viewing experience

**Why it matters**: Most media apps are designed for desktop/mobile first, then adapted poorly to TV. Jelly Shark starts with TV as the primary design target.

**Considerations**:
- Typography scaled for distance viewing
- Focus states that are obvious but not obnoxious
- Navigation depth that doesn't overwhelm
- Information hierarchy optimized for quick scanning
- Reduced cognitive load (fewer choices per screen, clearer paths)

**Background**: Drawing on experience designing for Starz, where interface quality directly impacts subscriber retention.

---

### 5. Open Source, Community-Driven
**What**: Apache 2.0 licensed, designed to be extensible

**Why it matters**: Jellyfin's strength is its open ecosystem. Jelly Shark embraces this rather than fighting it.

**Implications**:
- Design system published as separate package others can use
- Clear API boundaries for community contributions
- Theme sharing potential (users create and distribute themes)
- No vendor lock-in, no subscription bullshit

---

## Target Users

### Primary: Power Users & Enthusiasts
- Run their own Jellyfin servers
- Care about interface quality and customization
- Willing to configure settings to get things "just right"
- Appreciate good design and attention to detail
- Own Apple TV 4K or Apple Vision Pro

### Secondary: Design-Conscious Casual Users
- Don't want to think about configuration
- Want something that "just looks good"
- Appreciate when software respects their preferences
- Will discover customization options organically

---

## Success Criteria

### Launch (v1.0)
- [ ] Functional parity with core Jellyfin features (browse, search, playback)
- [ ] At least 5 distinct theme variants shipped
- [ ] Runtime theme switching works flawlessly
- [ ] Positive reception on r/jellyfin and Apple TV communities
- [ ] Zero critical bugs in playback or authentication

### 6 Months Post-Launch
- [ ] 10,000+ downloads
- [ ] 4.5+ star rating on App Store
- [ ] Active community creating custom themes
- [ ] Featured in Apple's Entertainment category (stretch goal)
- [ ] Mentioned as "the Jellyfin client" in community recommendations

### Long-Term Vision
- [ ] Design system adopted by other Jellyfin clients
- [ ] Template/starting point for other media apps
- [ ] Financially sustainable via donations or patronage (not required, but nice)

---

## Core Features (v1.0)

### Must Have
- Authentication with Jellyfin server
- Library browsing (movies, TV, music)
- Media detail views with metadata
- Playback with progress tracking
- Search functionality
- User profile switching
- Theme customization UI
- Settings management

### Should Have
- Continue watching / up next
- Recently added
- Favorites/collections
- Subtitle support
- Audio track selection
- Parental controls
- Downloads for offline (future)

### Nice to Have
- Top Shelf extension (tvOS)
- Immersive viewing modes (visionOS)
- Custom artwork/backgrounds
- Advanced filtering/sorting
- Watch party features

---

## Technical Constraints

**Must work with**:
- Any standard Jellyfin server (10.8+)
- Apple TV 4K (all generations with tvOS 26+)
- Apple Vision Pro (visionOS 26+)

**Performance targets**:
- <2s initial library load
- <500ms theme switching
- Smooth 60fps scrolling
- <100MB memory footprint (excluding media cache)

---

## Non-Goals (v1.0)

- iOS/iPadOS versions (maybe later)
- macOS version (maybe later)
- Support for other media servers (Plex, Emby)
- Social features
- Content recommendation algorithms
- Server management features
- DVR or live TV functionality

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Jellyfin API changes break compatibility | High | Version detection, graceful degradation |
| Theme system too complex for users | Medium | Excellent defaults, progressive disclosure |
| Performance issues with large libraries | High | Virtualization, pagination, caching |
| Platform APIs change between betas | Medium | Stay on stable releases, adapt quickly |
| Video playback library limitations | High | Choose established, maintained library |

---

## Marketing Angle

**Headline**: "The Jellyfin client that doesn't look like a Jellyfin client"

**Positioning**: Premium, Apple-quality experience for open-source media. Prove that open-source doesn't mean ugly or clunky.

**Key messages**:
- "Your media library, your style"
- "Designed for the big screen, not adapted from mobile"
- "Customization without complexity"
- "Open source, closed attention to detail"

---

## Open Questions

1. Freemium model with theme marketplace, or 100% free forever?
2. How aggressive should default animations be? (accessibility consideration)
3. Should theme customization be per-library or global-only?
4. Integration with other Jellyfin ecosystem tools (Intro Skipper, etc.)?
5. Support for plugin-based Jellyfin features?

---

## Milestones

### Foundation
- Architecture and design system documentation
- Core API integration and authentication
- Basic playback functionality
- Standard theme implementation (light + dark)

### Theming & Components
- Remaining launch themes (Horror, Action, Video Store)
- Component variant system
- Theme switching UI and runtime implementation
- Base component library

### Platform Polish
- tvOS-specific optimizations (focus engine, remote handling)
- visionOS-specific features (spatial layouts, immersion)
- Performance optimization
- Accessibility compliance

### Beta & Refinement
- Internal testing
- Community beta program
- Bug fixes and polish
- Performance tuning

### Launch
When it's actually good, not on a deadline.

---

## Resources & References

**Competition**:
- Swiftfin (official Jellyfin Swift client - functional but basic)
- Infuse (premium, multi-server - benchmark for quality)
- MrMC (Kodi fork - feature-rich but dated UI)

**Inspiration**:
- Apple TV+ app (navigation patterns)
- Netflix (information hierarchy)
- Plex (feature set, though UI is meh)
- Starz app (previous design work)

**Technical**:
- Jellyfin API docs: https://api.jellyfin.org
- Apple HIG for tvOS: https://developer.apple.com/design/human-interface-guidelines/designing-for-tvos
- Apple HIG for visionOS: https://developer.apple.com/design/human-interface-guidelines/designing-for-visionos
