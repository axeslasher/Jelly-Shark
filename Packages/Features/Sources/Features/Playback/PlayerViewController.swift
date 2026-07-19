#if canImport(UIKit)
    import AVKit
    import JellyfinKit
    import SwiftUI

    /// SwiftUI bridge to AVPlayerViewController
    ///
    /// Provides the native full-screen playback UI on tvOS and visionOS.
    /// On tvOS, audio and subtitle stream pickers are added to the transport
    /// bar so users can switch tracks that aren't part of the HLS playlist
    /// (Jellyfin's remux carries a single audio rendition; switching requires
    /// rebuilding the stream server-side).
    struct PlayerViewControllerRepresentable: UIViewControllerRepresentable {
        let player: AVPlayer
        let audioStreams: [MediaStreamInfo]
        let subtitleStreams: [MediaStreamInfo]
        let selectedAudioIndex: Int?
        let selectedSubtitleIndex: Int?
        let people: [CastMember]
        let headshotURL: (CastMember) -> URL?
        let onSelectAudio: (Int) -> Void
        let onSelectSubtitle: (Int?) -> Void

        /// Caches the cast tab so SwiftUI updates don't rebuild it — AVKit
        /// re-lays out its info tabs whenever the array is reassigned, which
        /// would flicker (and drop focus from) an open panel
        final class Coordinator {
            var castViewController: CastInfoViewController?
            var castPeople: [CastMember] = []
        }

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeUIViewController(context: Context) -> AVPlayerViewController {
            let controller = AVPlayerViewController()
            controller.player = player
            configureMenus(for: controller)
            configureCastTab(for: controller, coordinator: context.coordinator)
            return controller
        }

        func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
            if controller.player !== player {
                controller.player = player
            }
            configureMenus(for: controller)
            configureCastTab(for: controller, coordinator: context.coordinator)
        }

        private func configureCastTab(for controller: AVPlayerViewController, coordinator: Coordinator) {
            // The coordinator starts with empty people, matching AVKit's
            // default empty tab array, so the first pass with no cast is a
            // no-op rather than a reassignment
            guard coordinator.castPeople != people else {
                return
            }
            coordinator.castPeople = people
            coordinator.castViewController = people.isEmpty
                ? nil
                : CastInfoViewController(people: people, headshotURL: headshotURL)
            controller.customInfoViewControllers = coordinator.castViewController.map { [$0] } ?? []
        }

        private func configureMenus(for controller: AVPlayerViewController) {
            #if os(tvOS)
                var menus: [UIMenuElement] = []

                if audioStreams.count > 1 {
                    let actions = audioStreams.map { stream in
                        UIAction(
                            title: stream.displayTitle ?? stream.language ?? "Track \(stream.index)",
                            state: stream.index == selectedAudioIndex ? .on : .off,
                        ) { _ in
                            onSelectAudio(stream.index)
                        }
                    }
                    menus.append(UIMenu(
                        title: "Audio",
                        image: UIImage(systemName: "waveform"),
                        options: [.singleSelection],
                        children: actions,
                    ))
                }

                if !subtitleStreams.isEmpty {
                    var actions: [UIAction] = [
                        UIAction(
                            title: "Off",
                            state: selectedSubtitleIndex == nil ? .on : .off,
                        ) { _ in
                            onSelectSubtitle(nil)
                        },
                    ]
                    actions += subtitleStreams.map { stream in
                        UIAction(
                            title: stream.displayTitle ?? stream.language ?? "Track \(stream.index)",
                            state: stream.index == selectedSubtitleIndex ? .on : .off,
                        ) { _ in
                            onSelectSubtitle(stream.index)
                        }
                    }
                    menus.append(UIMenu(
                        title: "Subtitles",
                        image: UIImage(systemName: "captions.bubble"),
                        options: [.singleSelection],
                        children: actions,
                    ))
                }

                controller.transportBarCustomMenuItems = menus

                // The system's own subtitle picker is deliberately left in
                // place. Suppressing it (`allowedSubtitleOptionLanguages = []`)
                // was tried and reverted: AVKit owns subtitle *display* state
                // independently of the player item's media selection, so the
                // app's menu cannot actually take ownership — clearing the
                // legible selection latches AVKit off, and a later
                // programmatic re-select does not clear that latch. The
                // system picker is then the only way to get subtitles back,
                // which makes suppressing it strictly worse. See #91.
            #endif
        }
    }
#endif
