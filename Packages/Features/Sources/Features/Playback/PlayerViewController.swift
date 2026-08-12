#if canImport(UIKit)
    import AVKit
    import JellyfinKit
    import OSLog
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

        /// The player's own close control was used — tear down the presentation
        /// that hosts this controller.
        ///
        /// This app embeds `AVPlayerViewController` in a
        /// `UIViewControllerRepresentable` inside a `fullScreenCover`, which is
        /// exactly the case AVKit's documentation calls out: "If you've
        /// embedded the player view controller in another view, the delegate
        /// may need to manually dismiss the view controller." Nothing did, so
        /// AVKit's back button had nowhere to go — and when AVKit's fullscreen
        /// window went away anyway, the app's own window was still hidden
        /// behind it (#183).
        let onRequestDismiss: () -> Void

        /// Advance to the queued next episode — fired by the tvOS Up Next
        /// proposal (Play Next or the automatic-acceptance countdown). Unused
        /// on visionOS, whose overlay calls the view model directly (#186).
        var onAcceptUpNext: () -> Void = {}

        /// Decline the tvOS Up Next proposal, leaving the current episode
        /// playing. Reached only through the `didReject` safety net — the
        /// card offers no decline control. Unused on visionOS.
        var onDeclineUpNext: () -> Void = {}

        /// The tvOS Up Next card was dismissed without a decision (the back
        /// button): detach the proposal so AVKit cannot re-present it at the
        /// item boundary, but keep the queued episode — the episode plays out
        /// and post-roll autoplay advances. Unused on visionOS.
        var onDeferUpNext: () -> Void = {}

        /// Caches the cast tab so SwiftUI updates don't rebuild it — AVKit
        /// re-lays out its info tabs whenever the array is reassigned, which
        /// would flicker (and drop focus from) an open panel. The transport
        /// bar's custom items are cached for the same reason.
        ///
        /// Also the player's delegate: AVKit holds it weakly, and the
        /// coordinator is the only object here with the right lifetime.
        final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
            private static let logger = Logger(subsystem: "com.justinlascelle.jellyshark", category: "Playback")

            var castViewController: CastInfoViewController?
            var castPeople: [CastMember] = []

            // visionOS-only: tvOS gets the same choices natively via
            // `configureMenus`'s transport-bar menus. Audio and image
            // subtitles are separate tabs, each shown only when the source
            // carries it, so the tab bar never promises a control the file
            // can't honour. See `AudioTrackInfoViewController` /
            // `ImageSubtitleInfoViewController` for why they exist.
            //
            // For each tab: whether it belongs in `customInfoViewControllers`
            // is derived from its instance being non-nil; the paired signature
            // tracks the panel's *content* so an update pass refreshes it in
            // place only when the data actually changed — never on an unrelated
            // repaint, which would re-render the focused List and interrupt an
            // in-progress selection.
            #if os(visionOS)
                var audioTabViewController: AudioTrackInfoViewController?
                var audioTabSignature: String?

                var imageSubtitleTabViewController: ImageSubtitleInfoViewController?
                var imageSubtitleTabSignature: String?
            #endif

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

            /// Latest dismissal handler, refreshed every update pass for the
            /// same reason `onToggleFavorite` is: the delegate outlives the
            /// representable value that installed it.
            var onRequestDismiss: () -> Void = {}

            /// Up Next proposal handlers (tvOS), refreshed every update pass
            /// like the others. `onAcceptUpNext` advances to the next episode
            /// (fired by the viewer choosing Play Next *or* by AVKit's
            /// automatic-acceptance countdown); `onDeferUpNext` detaches the
            /// proposal after an undecided dismissal (the back button) while
            /// keeping the queued episode for post-roll autoplay;
            /// `onDeclineUpNext` clears the queued episode, reached only
            /// through the `didReject` safety net (#186).
            var onAcceptUpNext: () -> Void = {}
            var onDeclineUpNext: () -> Void = {}
            var onDeferUpNext: () -> Void = {}

            // The platforms expose disjoint halves of this protocol. The
            // *dismissal* family (`playerViewControllerShouldDismiss` and
            // friends) is tvOS-only but unused: AVKit shares the app's window
            // there, so the Menu button already unwinds correctly. visionOS
            // owns the *fullscreen-presentation* family (unavailable on tvOS),
            // which is the half #183 needs. The *content-proposal* family
            // below is also tvOS-only (`API_UNAVAILABLE(..., visionos)`), and
            // — unlike the dismissal family — tvOS now implements it, for the
            // pre-roll Up Next prompt (#186).
            #if os(visionOS)
                /// AVKit's fullscreen presentation is ending — its window is
                /// going away.
                ///
                /// The app's own window was hidden when AVKit went fullscreen
                /// and is restored only through AVKit's dismissal flow. Left
                /// alone, the cover stays presented over a hidden window: the
                /// back button appears dead, and whenever AVKit's window does
                /// go, only bare chrome is left (#183). Tearing down the cover
                /// here is what hands the window back.
                func playerViewController(
                    _: AVPlayerViewController,
                    willEndFullScreenPresentationWithAnimationCoordinator _: UIViewControllerTransitionCoordinator,
                ) {
                    // Logged because whether AVKit calls this at all, for a
                    // controller embedded in a representable, is not something
                    // any suite here can answer — the device log is the only
                    // place the answer shows up
                    Self.logger.info("[player] fullscreen presentation ending → dismissing")
                    onRequestDismiss()
                }

                /// AVKit asking the app to put its own interface back after a
                /// fullscreen exit. The app's answer is the same one: there is
                /// no interface to restore *underneath* this player, so the
                /// cover goes.
                func playerViewController(
                    _: AVPlayerViewController,
                    restoreUserInterfaceForFullScreenExitWithCompletionHandler completionHandler: @escaping (Bool) -> Void,
                ) {
                    Self.logger.info("[player] restore UI after fullscreen exit → dismissing")
                    onRequestDismiss()
                    completionHandler(true)
                }
            #endif

            // The Up Next / content-proposal family is tvOS-only
            // (`API_UNAVAILABLE(..., visionos)` on every symbol). The proposal
            // itself is attached to the player item by the engine; AVKit
            // presents the app's `UpNextProposalViewController` inside its own
            // hierarchy — there is no default card, a proposal without an
            // installed `contentProposalViewController` presents nothing — and
            // reports the outcome here (#186). visionOS keeps the SwiftUI
            // overlay.
            #if os(tvOS)
                func playerViewController(
                    _: AVPlayerViewController,
                    shouldPresent _: AVContentProposal,
                ) -> Bool {
                    // The card VC is installed once in `makeUIViewController`
                    // (a main-actor context) so this delegate — whose isolation
                    // differs across SDKs — only has to approve presentation.
                    Self.logger.info("[upnext] shouldPresent asked → yes")
                    return true
                }

                /// The viewer chose to advance, or AVKit's
                /// `automaticAcceptanceInterval` elapsed. The app owns loading
                /// the next content (the proposal carries no URL), so this
                /// calls straight into the same advance the old overlay did.
                func playerViewController(
                    _: AVPlayerViewController,
                    didAccept _: AVContentProposal,
                ) {
                    Self.logger.info("[upnext] proposal accepted → advancing")
                    onAcceptUpNext()
                }

                /// Safety net for an AVKit-initiated `.reject` (which tears
                /// down the player). No app code dismisses with `.reject` —
                /// the card's only button accepts, and the back button defers —
                /// so this normally does not fire; if AVKit ever rejects the
                /// proposal, clear the queued episode all the same.
                func playerViewController(
                    _: AVPlayerViewController,
                    didReject _: AVContentProposal,
                ) {
                    Self.logger.info("[upnext] proposal rejected → declining")
                    onDeclineUpNext()
                }
            #endif
        }

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeUIViewController(context: Context) -> AVPlayerViewController {
            let controller = AVPlayerViewController()
            controller.player = player
            controller.delegate = context.coordinator
            context.coordinator.onRequestDismiss = onRequestDismiss
            context.coordinator.onAcceptUpNext = onAcceptUpNext
            context.coordinator.onDeclineUpNext = onDeclineUpNext
            context.coordinator.onDeferUpNext = onDeferUpNext
            configureMenus(for: controller, coordinator: context.coordinator)
            configureInfoTabs(for: controller, coordinator: context.coordinator)
            #if os(tvOS)
                // Install the Up Next card once, here in a main-actor context;
                // AVKit reuses it for every proposal and the `shouldPresent`
                // delegate only approves presentation (#186). The dismissal
                // action routes through the coordinator's current handler.
                let coordinator = context.coordinator
                controller.contentProposalViewController = UpNextProposalViewController(
                    onDismissWithoutDecision: { [weak coordinator] in coordinator?.onDeferUpNext() },
                )
            #endif
            return controller
        }

        func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
            context.coordinator.onRequestDismiss = onRequestDismiss
            context.coordinator.onAcceptUpNext = onAcceptUpNext
            context.coordinator.onDeclineUpNext = onDeclineUpNext
            context.coordinator.onDeferUpNext = onDeferUpNext
            if controller.player !== player {
                controller.player = player
            }
            configureMenus(for: controller, coordinator: context.coordinator)
            configureInfoTabs(for: controller, coordinator: context.coordinator)
        }

        /// Builds `customInfoViewControllers` from the Cast & Crew tab and,
        /// on visionOS, the Audio and Image Subtitles tabs. Reassigning the
        /// array makes AVKit re-lay out its info tabs, so each sub-update
        /// reports whether *membership* changed; the array is only touched
        /// when it did, not on every data refresh.
        private func configureInfoTabs(for controller: AVPlayerViewController, coordinator: Coordinator) {
            let castMembershipChanged = updateCastTab(coordinator: coordinator)
            #if os(visionOS)
                let audioMembershipChanged = updateAudioTab(coordinator: coordinator)
                let subtitleMembershipChanged = updateImageSubtitleTab(coordinator: coordinator)
                let trackMembershipChanged = audioMembershipChanged || subtitleMembershipChanged
            #else
                let trackMembershipChanged = false
            #endif

            guard castMembershipChanged || trackMembershipChanged else { return }

            var tabs: [UIViewController] = []
            if let cast = coordinator.castViewController {
                tabs.append(cast)
            }
            #if os(visionOS)
                if let audio = coordinator.audioTabViewController {
                    tabs.append(audio)
                }
                if let imageSubtitle = coordinator.imageSubtitleTabViewController {
                    tabs.append(imageSubtitle)
                }
            #endif
            controller.customInfoViewControllers = tabs
        }

        /// - Returns: whether the tab's presence in the array changed.
        private func updateCastTab(coordinator: Coordinator) -> Bool {
            // The coordinator starts with empty people, matching AVKit's
            // default empty tab array, so the first pass with no cast is a
            // no-op rather than a reassignment
            guard coordinator.castPeople != people else {
                return false
            }
            coordinator.castPeople = people

            // Cast that changes but stays non-empty (e.g. an autoplay
            // episode transition) refreshes the existing tab's content in
            // place. Reassigning `customInfoViewControllers` instead would
            // re-lay out every tab and drop focus from an open one — the
            // visionOS track picker especially — so membership is reported
            // unchanged and the array is left alone.
            if !people.isEmpty, let existing = coordinator.castViewController {
                existing.rootView = CastInfoPanel(people: people, headshotURL: headshotURL)
                return false
            }

            coordinator.castViewController = people.isEmpty
                ? nil
                : CastInfoViewController(people: people, headshotURL: headshotURL)
            return true
        }

        #if os(visionOS)
            /// Alternate audio is offered only when there's a real choice —
            /// a lone track needs no picker.
            ///
            /// - Returns: whether the tab's presence in the array changed.
            private func updateAudioTab(coordinator: Coordinator) -> Bool {
                let shouldShow = audioStreams.count > 1
                let signature = audioDataSignature

                if shouldShow, let existing = coordinator.audioTabViewController {
                    // Membership is unchanged. Refresh the content in place
                    // only when the data behind it actually changed — an
                    // unrelated SwiftUI update (favorite toggle, Up Next
                    // appearing) must not re-render the focused List and
                    // interrupt a selection in progress. The refreshed panel
                    // also carries the newest closures, but the old ones
                    // already target the same view model, so skipping the
                    // refresh never strands a selection.
                    guard coordinator.audioTabSignature != signature else { return false }
                    coordinator.audioTabSignature = signature
                    existing.rootView = makeAudioPanel()
                    return false
                }

                // Membership is derived from the instance itself, so there is
                // no second Bool to keep in sync.
                guard shouldShow != (coordinator.audioTabViewController != nil) else { return false }
                coordinator.audioTabSignature = shouldShow ? signature : nil
                coordinator.audioTabViewController = shouldShow
                    ? AudioTrackInfoViewController(rootView: makeAudioPanel())
                    : nil
                return true
            }

            /// The image-subtitle tab appears for even a single burn-in track,
            /// since the choice there is the track versus Off. Text subtitles
            /// never reach here — AVKit's own captions picker owns them (#90).
            ///
            /// - Returns: whether the tab's presence in the array changed.
            private func updateImageSubtitleTab(coordinator: Coordinator) -> Bool {
                let burnInStreams = subtitleStreams.filter { !$0.isTextSubtitleStream }
                let shouldShow = !burnInStreams.isEmpty
                let signature = imageSubtitleDataSignature

                if shouldShow, let existing = coordinator.imageSubtitleTabViewController {
                    // See `updateAudioTab` — same in-place refresh discipline.
                    guard coordinator.imageSubtitleTabSignature != signature else { return false }
                    coordinator.imageSubtitleTabSignature = signature
                    existing.rootView = makeImageSubtitlePanel(burnInStreams: burnInStreams)
                    return false
                }

                guard shouldShow != (coordinator.imageSubtitleTabViewController != nil) else { return false }
                coordinator.imageSubtitleTabSignature = shouldShow ? signature : nil
                coordinator.imageSubtitleTabViewController = shouldShow
                    ? ImageSubtitleInfoViewController(rootView: makeImageSubtitlePanel(burnInStreams: burnInStreams))
                    : nil
                return true
            }

            private func makeAudioPanel() -> AudioTrackPanel {
                AudioTrackPanel(
                    audioStreams: audioStreams,
                    selectedAudioIndex: selectedAudioIndex,
                    onSelectAudio: onSelectAudio,
                )
            }

            private func makeImageSubtitlePanel(burnInStreams: [MediaStreamInfo]) -> ImageSubtitlePanel {
                ImageSubtitlePanel(
                    burnInSubtitleStreams: burnInStreams,
                    selectedSubtitleIndex: selectedSubtitleIndex,
                    onSelectSubtitle: onSelectSubtitle,
                )
            }
        #endif

        private func configureMenus(for controller: AVPlayerViewController, coordinator: Coordinator) {
            #if os(tvOS)
                syncFavoriteAction(coordinator: coordinator)

                // The track menus are rebuilt only when what they are built
                // from changes. Reassigning `transportBarCustomMenuItems`
                // re-lays out the bar, and a favorite toggle arrives as an
                // ordinary SwiftUI update — rebuilding then would pull the
                // bar out from under the viewer mid-press.
                let signature = trackDataSignature
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
                            title: stream.audioTrackTitle,
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

        /// What the audio surface is built from, so an update pass can tell a
        /// real change from a repaint. The visionOS Audio tab refreshes on it
        /// directly; the tvOS menu folds it into `trackDataSignature`. Both
        /// rebuild only when it changes, to avoid re-laying out a
        /// possibly-focused control on an unrelated update.
        private var audioDataSignature: String {
            let audio = audioStreams
                .map { "\($0.index):\($0.audioTrackTitle)" }
                .joined(separator: ",")
            return "\(audio)/\(selectedAudioIndex.map(String.init) ?? "-")"
        }

        /// The image-subtitle counterpart to `audioDataSignature`.
        private var imageSubtitleDataSignature: String {
            let burnIn = subtitleStreams
                .filter { !$0.isTextSubtitleStream }
                .map { "\($0.index):\(BurnInSubtitleLabel.title(for: $0))" }
                .joined(separator: ",")
            return "\(burnIn)/\(selectedSubtitleIndex.map(String.init) ?? "-")"
        }

        #if os(tvOS)
            /// The tvOS transport-bar menus are rebuilt as one unit, so their
            /// change-detection spans both concerns at once.
            private var trackDataSignature: String {
                "\(audioDataSignature)/\(imageSubtitleDataSignature)"
            }
        #endif

        #if os(tvOS)
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
