#if os(visionOS)
    import DesignSystem
    import JellyfinKit
    import SwiftUI
    import UIKit

    /// The player's audio / burn-in-subtitle picker tab, visionOS only.
    ///
    /// tvOS gets this same choice natively in the transport bar
    /// (`configureMenus`'s `UIMenu`s); visionOS has no such menu, and a
    /// SwiftUI view drawn as a sibling of `AVPlayerViewController` renders
    /// behind its window and is never seen (#182). Handing the picker to
    /// AVKit via `customInfoViewControllers` — the same mechanism
    /// `CastInfoViewController` already uses successfully on this platform —
    /// puts it inside the window that's actually visible.
    ///
    /// Unlike the cast tab, this content is interactive, so the coordinator
    /// keeps this instance alive across updates and refreshes `rootView` in
    /// place (see `PlayerViewControllerRepresentable.updateTrackSelectionTab`)
    /// rather than rebuilding it — reassigning `customInfoViewControllers`
    /// re-lays out AVKit's tabs, which would drop focus from an open panel.
    final class TrackSelectionInfoViewController: UIHostingController<TrackSelectionPanel> {
        override init(rootView: TrackSelectionPanel) {
            super.init(rootView: rootView)
            // AVKit reads the title for the tab label at attach time
            title = String(localized: "Audio & Subtitles")
            preferredContentSize = CGSize(width: 960, height: 360)
            view.backgroundColor = .clear
        }

        @available(*, unavailable)
        @MainActor dynamic required init?(coder _: NSCoder) {
            fatalError("init(coder:) is not supported")
        }
    }

    /// Audio and burn-in subtitle picker shown inside AVKit's info area.
    ///
    /// Text subtitles are deliberately absent: they're HLS renditions AVKit's
    /// own media-selection UI already handles natively (#90). This carries
    /// only the streams AVKit cannot see — alternate audio and burn-in
    /// (image) subtitle tracks, both of which need a stream rebuild via
    /// `PlaybackViewModel.applySelection`.
    struct TrackSelectionPanel: View {
        let audioStreams: [MediaStreamInfo]
        let burnInSubtitleStreams: [MediaStreamInfo]
        let selectedAudioIndex: Int?
        let selectedSubtitleIndex: Int?
        let onSelectAudio: (Int) -> Void
        let onSelectSubtitle: (Int?) -> Void

        var body: some View {
            List {
                if audioStreams.count > 1 {
                    Section {
                        Picker("Audio", selection: audioSelection) {
                            ForEach(audioStreams, id: \.index) { stream in
                                Text(trackTitle(for: stream)).tag(stream.index)
                            }
                        }
                        .pickerStyle(.inline)
                    } header: {
                        Text("Audio")
                    }
                }

                if !burnInSubtitleStreams.isEmpty {
                    Section {
                        Picker("Image Subtitles", selection: subtitleSelection) {
                            Text("Off").tag(Int?.none)
                            ForEach(burnInSubtitleStreams, id: \.index) { stream in
                                Text(BurnInSubtitleLabel.title(for: stream)).tag(Int?.some(stream.index))
                            }
                        }
                        .pickerStyle(.inline)
                    } header: {
                        Text("Image Subtitles")
                    }
                }
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

        private var subtitleSelection: Binding<Int?> {
            Binding(
                get: { selectedSubtitleIndex },
                set: { index in onSelectSubtitle(index) },
            )
        }

        private func trackTitle(for stream: MediaStreamInfo) -> String {
            stream.displayTitle ?? stream.language ?? "Track \(stream.index)"
        }
    }
#endif
