#if !os(tvOS)
    import SwiftUI

    /// A button style that decorates nothing, so the component owns its own
    /// hover treatment.
    ///
    /// visionOS attaches an automatic hover effect to the **built-in** button
    /// styles, shaped by the system from the button's bounds — a capsule, whose
    /// curve then cuts across the captions of a card lockup. That effect can't
    /// be reshaped: `contentShape(.hoverEffect, …)` reaches only effects the app
    /// applies itself, which is what commit "Give visionOS its own hover
    /// treatment" established on device after declaring shapes changed nothing.
    /// Nor can it be suppressed — `hoverEffectDisabled` takes everything nested
    /// below it along, per its own documentation. Since SwiftUI only decorates
    /// the styles it owns, a custom style gets no effect at all, which is the
    /// point: the component applies `hoverEffect` where it belongs and declares
    /// that effect's shape.
    ///
    /// tvOS never uses this. There, `.borderless` builds the focus lockup — the
    /// artwork lift with the captions sliding aside — which is the treatment
    /// that platform wants and nothing here should touch.
    struct CardButtonStyle: ButtonStyle {
        /// Set for controls whose hover effect belongs to the button itself —
        /// the paragraph buttons, which have no artwork to hang it on. The
        /// label is padded by the standard margins so the glow clears the text,
        /// and the effect is declared at this radius.
        ///
        /// The padding goes **inside** the style deliberately. Applied from the
        /// outside it would grow only the hover region, leaving a band that
        /// lights up under gaze but that a pinch can't activate, since
        /// `contentShape(.hoverEffect, …)` leaves the interaction shape alone by
        /// design. Padding the label instead grows the button, so hover, hit
        /// area, and press all agree on the same rectangle.
        ///
        /// Cards leave this nil: their effect lives on the artwork.
        var hoverShapeRadius: CGFloat?

        func makeBody(configuration: Configuration) -> some View {
            hoverTreatment(configuration.label)
                // The one thing the built-in styles did that's worth keeping:
                // press feedback, since these are real targets here.
                .scaleEffect(configuration.isPressed ? MotionTokens.pressedScale : 1)
                .animation(MotionTokens.fast, value: configuration.isPressed)
        }

        @ViewBuilder
        private func hoverTreatment(_ label: Configuration.Label) -> some View {
            if let hoverShapeRadius {
                label
                    .padding(.horizontal, SpacingTokens.md)
                    .padding(.vertical, SpacingTokens.sm)
                    .contentShape(.hoverEffect, .rect(cornerRadius: hoverShapeRadius))
                    .hoverEffect(.highlight)
            } else {
                label
            }
        }
    }

    /// visionOS-only (the file is compiled out on tvOS). Hover glow and press
    /// scale need canvas interaction; the static render shows resting states.
    private struct CardButtonStylePreview: View {
        @Environment(\.theme) private var theme

        var body: some View {
            VStack(spacing: SpacingTokens.lg) {
                Button {} label: {
                    Text("Paragraph button — owns its hover glow")
                        .jsStyle(.body)
                        .foregroundStyle(theme.primary)
                }
                .buttonStyle(CardButtonStyle(hoverShapeRadius: theme.cornerRadius))

                Button {} label: {
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .fill(theme.surface)
                        .frame(width: 320, height: 180)
                }
                .buttonStyle(CardButtonStyle())
            }
            .padding(SpacingTokens.xl)
        }
    }

    #Preview("Standard") {
        CardButtonStylePreview()
            .previewCanvas()
    }

    #Preview("Horror") {
        CardButtonStylePreview()
            .previewCanvas(.horror)
    }

    #Preview("Action") {
        CardButtonStylePreview()
            .previewCanvas(.action)
    }

    #Preview("Video Store") {
        CardButtonStylePreview()
            .previewCanvas(.videoStore)
    }

    #Preview("Sci-Fi") {
        CardButtonStylePreview()
            .previewCanvas(.sciFi)
    }
#endif
