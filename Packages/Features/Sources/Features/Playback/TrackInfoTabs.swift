#if os(visionOS)
    import DesignSystem
    import JellyfinKit
    import SwiftUI
    import UIKit

    /// The player's audio / image-subtitle picker tabs, visionOS only.
    ///
    /// tvOS gets these same choices natively in the transport bar
    /// (`configureMenus`'s `UIMenu`s); visionOS has no such menu, and a
    /// SwiftUI view drawn as a sibling of `AVPlayerViewController` renders
    /// behind its window and is never seen (#182). Handing each picker to
    /// AVKit via `customInfoViewControllers` — the same mechanism
    /// `CastInfoViewController` uses — puts it inside the window that's
    /// actually visible.
    ///
    /// Each concern is its own tab, added only when the source carries it (see
    /// `PlayerViewControllerRepresentable.updateAudioTab` /
    /// `updateImageSubtitleTab`), so the tab bar never promises a control the
    /// file can't honour. The content is interactive, so the coordinator keeps
    /// each instance alive across updates and refreshes `rootView` in place
    /// rather than reassigning `customInfoViewControllers`, which would re-lay
    /// out AVKit's tabs and drop focus from an open panel.
    final class AudioTrackInfoViewController: UIHostingController<AudioTrackPanel> {
        override init(rootView: AudioTrackPanel) {
            super.init(rootView: rootView)
            // AVKit reads the title for the tab label at attach time
            title = String(localized: "Audio")
            preferredContentSize = CGSize(width: 960, height: 360)
            view.backgroundColor = .clear
        }

        @available(*, unavailable)
        @MainActor dynamic required init?(coder _: NSCoder) {
            fatalError("init(coder:) is not supported")
        }
    }

    /// The image-subtitle sibling of `AudioTrackInfoViewController`.
    final class ImageSubtitleInfoViewController: UIHostingController<ImageSubtitlePanel> {
        override init(rootView: ImageSubtitlePanel) {
            super.init(rootView: rootView)
            title = String(localized: "Image Subtitles")
            preferredContentSize = CGSize(width: 960, height: 360)
            view.backgroundColor = .clear
        }

        @available(*, unavailable)
        @MainActor dynamic required init?(coder _: NSCoder) {
            fatalError("init(coder:) is not supported")
        }
    }

    /// Alternate-audio picker for the Audio tab.
    struct AudioTrackPanel: View {
        let audioStreams: [MediaStreamInfo]
        let selectedAudioIndex: Int?
        let onSelectAudio: (Int) -> Void

        var body: some View {
            // The tab is already titled "Audio", so the picker's own label is
            // hidden — left visible it repeats the title as a header row.
            List {
                Picker("Audio", selection: audioSelection) {
                    ForEach(audioStreams, id: \.index) { stream in
                        Text(stream.audioTrackTitle).tag(stream.index)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .scrollContentBackground(.hidden)
            .withThemeEnvironment()
        }

        private var audioSelection: Binding<Int> {
            Binding(
                get: { selectedAudioIndex ?? -1 },
                set: { index in onSelectAudio(index) },
            )
        }
    }

    /// Burn-in (image) subtitle picker for the Image Subtitles tab.
    ///
    /// Text subtitles are deliberately absent: they're HLS renditions AVKit's
    /// own media-selection UI already handles natively (#90). This carries
    /// only the image tracks AVKit cannot see, each of which needs a stream
    /// rebuild via `PlaybackViewModel.applySelection`.
    struct ImageSubtitlePanel: View {
        let burnInSubtitleStreams: [MediaStreamInfo]
        let selectedSubtitleIndex: Int?
        let onSelectSubtitle: (Int?) -> Void

        var body: some View {
            // Tab-titled "Image Subtitles"; the picker label is hidden for the
            // same reason as the Audio tab.
            List {
                Picker("Image Subtitles", selection: subtitleSelection) {
                    Text("Off").tag(Int?.none)
                    ForEach(burnInSubtitleStreams, id: \.index) { stream in
                        Text(BurnInSubtitleLabel.title(for: stream)).tag(Int?.some(stream.index))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .scrollContentBackground(.hidden)
            .withThemeEnvironment()
        }

        private var subtitleSelection: Binding<Int?> {
            Binding(
                get: { selectedSubtitleIndex },
                set: { index in onSelectSubtitle(index) },
            )
        }
    }
#endif
