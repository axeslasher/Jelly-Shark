# Design System

## Philosophy

Jelly Shark's design system is built around **genre-inspired theming** - visual languages that evoke the aesthetic and emotion of different film genres and media experiences. This isn't arbitrary styling; each theme tells a story and creates atmosphere appropriate to what users are watching.

The system has two layers:
1. **Themes**: High-level visual language (color, typography, motion) inspired by film genres
2. **Component Variants**: Granular layout and presentation options that work within any theme

Users can switch themes globally while customizing individual components to their preference - all adhering to the chosen theme's design language.

---

## Core Themes (v1.0)

### Standard
**Concept**: Elegant, timeless, Apple-quality baseline

**Visual Language**:
- Clean sans-serif typography (SF Pro Display)
- Neutral color palette with subtle accent
- Smooth, refined animations
- High contrast for readability
- Generous whitespace and breathing room

**Mood**: Professional, unobtrusive, lets content shine

**Use Case**: Default experience, broad appeal, content-agnostic

**Color Palette** (light/dark): (WIP - not final)
```
Light Mode:
- Background: Off-white (#F5F5F7)
- Surface: White (#FFFFFF)
- Primary: Deep Blue (#1D1D1F)
- Accent: Vibrant Blue (#007AFF)
- Text: Charcoal (#1D1D1F)

Dark Mode:
- Background: True Black (#000000) 
- Surface: Dark Gray (#1C1C1E)
- Primary: Off-White (#F5F5F7)
- Accent: Bright Blue (#0A84FF)
- Text: Off-White (#F5F5F7)
```

---

### Horror
**Concept**: Atmospheric dread, visceral intensity

**Visual Language**:
- Angular, slightly distressed typography (impact cuts, sharp serifs)
- Deep reds, blacks, desaturated palette
- Harsher contrast, dramatic shadows
- Slower, tension-building animations
- Tighter letter spacing, compressed layouts

**Mood**: Unsettling, intense, genre-appropriate atmosphere

**Use Case**: Horror libraries, late-night viewing, users who want edge

**Color Palette** (light/dark): (WIP - not final)
```
Light Mode (Blood-Stained):
- Background: Dirty White (#E8E5E0)
- Surface: Aged Paper (#D4CFC8)
- Primary: Deep Crimson (#8B0000)
- Accent: Blood Red (#DC143C)
- Text: Near Black (#1A1A1A)

Dark Mode (Midnight):
- Background: Void Black (#0A0A0A)
- Surface: Charcoal (#1A1A1A)
- Primary: Deep Red (#660000)
- Accent: Arterial Red (#B22222)
- Text: Bone White (#E8E5E0)
```

**Typography**: 
- Headers: Condensed, aggressive (heavier weight)
- Body: Slightly increased tracking for unease
- Focus states: Sharp, jagged edges

---

### Action
**Concept**: Kinetic energy, technological precision

**Visual Language**:
- Geometric, technical sans-serifs (think Eurostile, Bank Gothic)
- Electric blues, stark blacks, chrome accents
- High-speed, snappy animations
- Sharp angles, hard edges
- Condensed typography for intensity

**Mood**: Adrenaline, forward momentum, sleek intensity

**Use Case**: Action libraries, high-energy browsing experience

**Color Palette** (light/dark): (WIP - not final)
```
Light Mode (Titanium):
- Background: Cool Gray (#E5E8EB)
- Surface: Brushed Metal (#D1D5DB)
- Primary: Steel Blue (#2C3E50)
- Accent: Electric Blue (#00D4FF)
- Text: Gunmetal (#34495E)

Dark Mode (Tactical):
- Background: Carbon Black (#0F1419)
- Surface: Matte Black (#1A1F25)
- Primary: Chrome (#BFC9D9)
- Accent: Neon Blue (#00E5FF)
- Text: Ice Blue (#E5F1FF)
```

**Motion**: 
- Fast transitions (200ms vs standard 300ms)
- Parallax effects on scroll
- Snap animations, no easing curves

---

### Video Store
**Concept**: 90s nostalgia, Blockbuster Video aesthetic

**Visual Language**:
- Rounded, friendly typography (throwback to 90s signage)
- Blue and gold/yellow color scheme (Blockbuster homage)
- Playful, slightly bouncy animations
- Softer edges, warmer feel
- VHS-inspired textures (subtle scan lines, slight grain)

**Mood**: Nostalgic, warm, Friday night rental excitement

**Use Case**: Users who grew up with video rentals, retro aesthetic lovers

**Color Palette** (light/dark): (WIP - not final)
```
Light Mode (Rental Floor):
- Background: Warm Beige (#F0E8D8)
- Surface: Cream (#FAF5E8)
- Primary: Blockbuster Blue (#003DA5)
- Accent: Ticket Gold (#FFD700)
- Text: Deep Blue (#001D52)

Dark Mode (After Hours):
- Background: Deep Navy (#001D3D)
- Surface: Dark Blue (#002952)
- Primary: Gold (#FFD700)
- Accent: Bright Blue (#4A90E2)
- Text: Cream (#FAF5E8)
```

**Details**:
- Border radius: More pronounced (12px vs 8px)
- Shadows: Softer, more lifted
- Optional: Subtle VHS scan line overlay (toggleable)

---

## Theme Architecture

### Design Tokens
All themes inherit from a base token structure:
(WIP - not final)
```swift
protocol Theme {
    // Colors
    var background: Color { get }
    var surface: Color { get }
    var primary: Color { get }
    var accent: Color { get }
    var text: Color { get }
    var textSecondary: Color { get }
    
    // Typography
    var fontFamily: String { get }
    var fontWeightDisplay: Font.Weight { get }
    var fontWeightBody: Font.Weight { get }
    var letterSpacing: CGFloat { get }
    
    // Spacing
    var spacingUnit: CGFloat { get }
    var cardPadding: CGFloat { get }
    var sectionSpacing: CGFloat { get }
    
    // Motion
    var transitionDuration: TimeInterval { get }
    var animationCurve: Animation { get }
    
    // Geometry
    var cornerRadius: CGFloat { get }
    var borderWidth: CGFloat { get }
}
```

### Theme Switching
- **Runtime switching**: No app restart required
- **Animated transitions**: Smooth crossfade between themes (500ms)
- **Persistence**: User choice saved in SwiftData
- **Per-library override**: Future feature (global theme + per-library exceptions)

---

## Component Variants (WIP - not final)

Component variants are **layout and presentation options** that work within any theme. They adapt to the active theme's visual language while offering structural flexibility.

### Variant Philosophy
- **Theme-agnostic structure**: Variants define layout, not color/typography
- **Theme-aware rendering**: Components pull styling from active theme
- **User configurable**: Variants can be set per-component type in settings

---

### Media Card Variants

**PosterDominant** (Default)
- Poster takes 70% of card
- Minimal metadata overlay
- Title + year on hover/focus
- Best for: Browsing by artwork

**Landscape**
- Wide aspect ratio (16:9)
- Backdrop image instead of poster
- More metadata visible (rating, runtime, genre)
- Best for: Continuing watching, TV shows

**Minimal**
- Poster only, no text unless focused
- Ultra-clean, image-first
- Best for: Immersive browsing

**Detailed**
- Poster + full metadata sidebar
- Plot summary, cast, ratings
- Larger card footprint
- Best for: Discovery mode, indecisive browsing

**Immersive** (visionOS focused)
- Full-bleed backdrop with depth
- Floating poster with parallax
- Spatial audio cues on focus
- Best for: visionOS showcase

---

### Detail Page Hero Variants

**Cinematic** (Default)
- Full-width backdrop with gradient overlay
- Floating poster on left
- Metadata on right
- Play button prominent

**Minimal**
- Smaller backdrop thumbnail
- Content-first layout
- Poster as thumbnail, not hero
- Best for: Information-dense preference

**Split**
- Backdrop left, all info right
- No overlay, clean division
- Traditional layout
- Best for: Readability focus

**Poster-First**
- Large centered poster
- Metadata below in columns
- Best for: Poster art appreciation

---

### Navigation Variants

**Tab Bar** (tvOS default)
- Bottom-aligned tabs
- Standard Apple TV pattern
- Best for: Familiar navigation

**Sidebar**
- Left-aligned vertical menu
- More options visible
- Best for: Power users, many sections

**Immersive Top**
- Translucent top bar
- Dissolves when scrolling
- Best for: Content-first experience

---

### List/Grid Density Variants

**Compact**
- Smaller cards, more per row
- Tighter spacing
- Best for: Large libraries, quick scanning

**Comfortable** (Default)
- Balanced size and spacing
- 4-5 items per row on TV
- Best for: General use

**Spacious**
- Larger cards, fewer per row
- Generous padding
- Best for: Relaxed browsing, accessibility

---

## Typography Scale

### Standard Theme (WIP - not final)
```
Display: SF Pro Display, 52pt, Bold
Headline: SF Pro Display, 32pt, Semibold
Title: SF Pro Display, 24pt, Medium
Body: SF Pro Text, 18pt, Regular
Caption: SF Pro Text, 14pt, Regular
```
 
### Horror Theme (WIP - not final)
```
Display: Condensed Gothic, 48pt, Heavy (tighter tracking)
Headline: Serif Display, 30pt, Bold
Title: Sans Condensed, 22pt, Bold
Body: Sans, 17pt, Regular (slightly increased tracking)
Caption: Sans, 13pt, Regular
```

### Action Theme (WIP - not final)
```
Display: Geometric Sans, 54pt, Black (ultra tight tracking)
Headline: Technical Sans, 32pt, Bold
Title: Technical Sans, 24pt, Semibold  
Body: Technical Sans, 18pt, Regular
Caption: Technical Sans, 14pt, Regular
```

### Video Store Theme (WIP - not final)
```
Display: Rounded Sans, 50pt, Bold
Headline: Rounded Sans, 30pt, Semibold
Title: Rounded Sans, 24pt, Medium
Body: Friendly Sans, 18pt, Regular
Caption: Friendly Sans, 14pt, Regular
```

---

## Motion & Animation (WIP - not final)

### Standard
- Duration: 300ms
- Curve: Ease-in-out
- Focus transitions: Smooth scale (1.0 → 1.05)

### Horror
- Duration: 400ms (slower, more tension)
- Curve: Ease-in (sudden stop)
- Focus transitions: Sharp snap, subtle shake

### Action
- Duration: 200ms (faster)
- Curve: Ease-out (explosive start)
- Focus transitions: Quick scale with parallax

### Video Store  
- Duration: 350ms
- Curve: Spring animation (bounce)
- Focus transitions: Playful lift with rotation

---

## Accessibility

All themes must maintain:
- **WCAG AA contrast ratios** minimum
- **Dynamic Type support** (scale with system settings)
- **VoiceOver labels** for all interactive elements
- **Focus indicators** that work in all themes (minimum 3:1 contrast)
- **Reduce Motion** support (disable complex animations)

---

## Implementation Strategy

### Phase 1: Foundation
1. Define base `Theme` protocol
2. Implement Standard theme (light + dark)
3. Build token system and theme provider
4. Create theme switching UI

### Phase 2: Variants
5. Implement Horror theme
6. Implement Action theme  
7. Implement Video Store theme
8. Add component variant system

### Phase 3: Customization
9. Per-component variant settings UI
10. Theme preview system
11. Import/export themes (future)

---

## Future Considerations

**User-Created Themes**:
- Theme files as JSON/YAML
- Community theme sharing
- Theme marketplace?

**Dynamic Themes**:
- Extract colors from content (like iOS dynamic wallpapers)
- Time-of-day themes (auto dark mode at sunset)

**Platform-Specific Adaptations**:
- visionOS: Depth and material adjustments
- tvOS: Focus engine optimizations per theme

---

## Design Tools (WIP - not final)

**Figma Library**: TBD (for designing new components/themes)  
**Asset Export**: SF Symbols for icons, custom assets per theme  
**Documentation**: Living style guide in-app (developer mode)

---

## Open Questions

1. Should themes affect sound design (UI sounds per theme)?
2. How granular should component customization be before it's overwhelming?
3. Theme presets vs. full custom builder?
4. Seasonal themes (Halloween, Christmas)?
