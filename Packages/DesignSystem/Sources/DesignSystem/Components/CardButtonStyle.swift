#if !os(tvOS)
    import SwiftUI

    /// A button style that decorates nothing, so the component owns its own
    /// hover treatment.
    ///
    /// visionOS attaches an automatic hover effect to the **built-in** button
    /// styles, shaped by the system from the button's bounds — a capsule, whose
    /// curve then cuts across the captions of a card lockup. That effect can't
    /// be reshaped (`contentShape(.hoverEffect, …)` reaches only effects the app
    /// applies itself — verified on device, #139) and it can't be suppressed
    /// (`hoverEffectDisabled` takes everything nested below with it, per its
    /// docs). Since SwiftUI only decorates the styles it owns, a custom style
    /// gets no effect at all — which is the point: the card then applies
    /// `hoverEffect` to the artwork alone and declares that effect's shape.
    ///
    /// tvOS never uses this. There, `.borderless` builds the focus lockup — the
    /// artwork lift with the captions sliding aside — which is the treatment
    /// that platform wants and nothing here should touch.
    struct CardButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                // The one thing the built-in styles did that's worth keeping:
                // press feedback, since a card is a real target here.
                .scaleEffect(configuration.isPressed ? MotionTokens.pressedScale : 1)
                .animation(MotionTokens.fast, value: configuration.isPressed)
        }
    }
#endif
