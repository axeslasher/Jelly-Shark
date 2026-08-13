import DesignSystem
import SwiftUI

#if DEBUG
    /// The shared environment every Features screen expects, packaged as a
    /// preview trait so a preview can't forget a line of it (PersonDetailView
    /// once shipped without its theme this way):
    ///
    ///     #Preview(traits: .featuresEnvironment) { ... }
    ///     #Preview("Horror", traits: .featuresEnvironment(theme: .horror)) { ... }
    ///
    /// The session has no client, so screens render their disconnected/empty
    /// states and artwork comes from blur hashes; the theme manager never
    /// persists (`ThemeManager.preview`).
    struct FeaturesPreview: PreviewModifier {
        var themeId: ThemeIdentifier = .standard

        func body(content: Content, context _: Void) -> some View {
            content
                // `previewCanvas` also paints the theme's background behind
                // the content, so section previews sit on the same ground
                // their real screens paint (screens painting their own
                // background just cover it).
                .previewCanvas(themeId)
                .environment(AppSession())
                .environment(ServerConnectionViewModel())
                .environment(HomePreferences())
                .environment(PlaybackPreferences())
        }
    }

    extension PreviewTrait where T == Preview.ViewTraits {
        static var featuresEnvironment: Self {
            .modifier(FeaturesPreview())
        }

        static func featuresEnvironment(theme: ThemeIdentifier) -> Self {
            .modifier(FeaturesPreview(themeId: theme))
        }
    }
#endif
