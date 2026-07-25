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
        let isFavorite: Bool
        let headshotURL: (CastMember) -> URL?
        let onSelectAudio: (Int) -> Void
        let onSelectSubtitle: (Int?) -> Void
        let onToggleFavorite: () -> Void

        /// Caches the cast tab so SwiftUI updates don't rebuild it — AVKit
        /// re-lays out its info tabs whenever the array is reassigned, which
        /// would flicker (and drop focus from) an open panel. The transport
        /// bar's custom items are cached for the same reason.
        final class Coordinator {
            var castViewController: CastInfoViewController?
            var castPeople: [CastMember] = []

            /// The favorite item, built once per player view controller and
            /// mutated in place afterwards: a reassignment of
            /// `transportBarCustomMenuItems` re-lays out the bar the heart
            /// lives in, so the glyph swaps on the action itself (the
            /// pattern AVKit's own documentation shows).
            var favoriteAction: UIAction?

            /// Favorite state the cached action's glyph currently shows
            var favoriteState = false

            /// Latest toggle handler. The action is built once, so it calls
            /// through the coordinator rather than capturing a closure from
            /// the representable value that made it.
            var onToggleFavorite: () -> Void = {}

            /// What the track menus were last built from; unchanged means
            /// the assigned items are still correct
            var trackMenuSignature: String?
        }

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeUIViewController(context: Context) -> AVPlayerViewController {
            let controller = AVPlayerViewController()
            controller.player = player
            configureMenus(for: controller, coordinator: context.coordinator)
            configureCastTab(for: controller, coordinator: context.coordinator)
            return controller
        }

        func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
            if controller.player !== player {
                controller.player = player
            }
            configureMenus(for: controller, coordinator: context.coordinator)
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

        private func configureMenus(for controller: AVPlayerViewController, coordinator: Coordinator) {
            #if os(tvOS)
                syncFavoriteAction(coordinator: coordinator)

                // The track menus are rebuilt only when what they are built
                // from changes. Reassigning `transportBarCustomMenuItems`
                // re-lays out the bar, and a favorite toggle arrives as an
                // ordinary SwiftUI update — rebuilding then would pull the
                // bar out from under the viewer mid-press.
                let signature = trackMenuSignature
                guard coordinator.trackMenuSignature != signature else { return }
                coordinator.trackMenuSignature = signature

                var menus: [UIMenuElement] = []

                // First. The heart is built on the very first pass and is
                // never conditional, so leading the custom items is a stable
                // position — unlike the track menus, which come and go with
                // the source's streams.
                if let favoriteAction = coordinator.favoriteAction {
                    menus.append(favoriteAction)
                }

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

                // AVKit's native picker owns text subtitles — they are HLS
                // renditions it can select directly, correctly timed via the
                // loopback server's playlist rewrite (#90). The app's menu
                // carries only what AVKit structurally cannot: burn-in
                // (image) tracks, which exist solely as a server-side
                // re-encode. When a source has none, no app menu appears at
                // all. The app must never programmatically clear the legible
                // selection: that latches AVKit's subtitle display off
                // process-wide (#91).
                let burnInStreams = subtitleStreams.filter { !$0.isTextSubtitleStream }
                if !burnInStreams.isEmpty {
                    var actions: [UIAction] = [
                        UIAction(
                            title: "Off",
                            state: selectedSubtitleIndex == nil ? .on : .off,
                        ) { _ in
                            onSelectSubtitle(nil)
                        },
                    ]
                    actions += burnInStreams.map { stream in
                        UIAction(
                            title: BurnInSubtitleLabel.title(for: stream),
                            state: stream.index == selectedSubtitleIndex ? .on : .off,
                        ) { _ in
                            onSelectSubtitle(stream.index)
                        }
                    }
                    // Distinct name and glyph from AVKit's own picker (which
                    // renders the captions bubble): at transport-bar size the
                    // two menus are told apart by icon alone
                    menus.append(UIMenu(
                        title: "Image Subtitles",
                        subtitle: "Requires reload",
                        image: UIImage(systemName: "text.below.photo"),
                        options: [.singleSelection],
                        children: actions,
                    ))
                }

                controller.transportBarCustomMenuItems = menus
            #endif
        }

        #if os(tvOS)
            /// Everything the audio and image-subtitle menus are built from,
            /// so an update pass can tell a real change from a repaint
            private var trackMenuSignature: String {
                let audio = audioStreams
                    .map { "\($0.index):\($0.displayTitle ?? $0.language ?? "")" }
                    .joined(separator: ",")
                let burnIn = subtitleStreams
                    .filter { !$0.isTextSubtitleStream }
                    .map { "\($0.index):\(BurnInSubtitleLabel.title(for: $0))" }
                    .joined(separator: ",")
                return """
                \(audio)/\(burnIn)/\
                \(selectedAudioIndex.map(String.init) ?? "-")/\
                \(selectedSubtitleIndex.map(String.init) ?? "-")
                """
            }

            /// Build the favorite item on the first pass, then keep its glyph
            /// in sync with the view model — which is also how a failed
            /// toggle's revert reaches the transport bar.
            private func syncFavoriteAction(coordinator: Coordinator) {
                // The action outlives the representable value that made it,
                // so the handler always calls the newest closure
                coordinator.onToggleFavorite = onToggleFavorite

                guard let action = coordinator.favoriteAction else {
                    coordinator.favoriteState = isFavorite
                    coordinator.favoriteAction = UIAction(
                        title: "Favorite",
                        image: Self.heartImage(filled: isFavorite),
                    ) { [weak coordinator] action in
                        guard let coordinator else { return }
                        // Swap the glyph on the press rather than waiting
                        // for the view model's update to come back around
                        coordinator.favoriteState.toggle()
                        action.image = Self.heartImage(filled: coordinator.favoriteState)
                        coordinator.onToggleFavorite()
                    }
                    return
                }

                guard coordinator.favoriteState != isFavorite else { return }
                coordinator.favoriteState = isFavorite
                action.image = Self.heartImage(filled: isFavorite)
            }

            private static func heartImage(filled: Bool) -> UIImage? {
                UIImage(systemName: filled ? "heart.fill" : "heart")
            }
        #endif
    }
#endif
