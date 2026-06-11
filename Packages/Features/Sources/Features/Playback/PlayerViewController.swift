#if canImport(UIKit)
import AVKit
import SwiftUI
import JellyfinKit

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
    let onSelectAudio: (Int) -> Void
    let onSelectSubtitle: (Int?) -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        configureMenus(for: controller)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
        configureMenus(for: controller)
    }

    private func configureMenus(for controller: AVPlayerViewController) {
        #if os(tvOS)
        var menus: [UIMenuElement] = []

        if audioStreams.count > 1 {
            let actions = audioStreams.map { stream in
                UIAction(
                    title: stream.displayTitle ?? stream.language ?? "Track \(stream.index)",
                    state: stream.index == selectedAudioIndex ? .on : .off
                ) { _ in
                    onSelectAudio(stream.index)
                }
            }
            menus.append(UIMenu(
                title: "Audio",
                image: UIImage(systemName: "waveform"),
                options: [.singleSelection],
                children: actions
            ))
        }

        if !subtitleStreams.isEmpty {
            var actions: [UIAction] = [
                UIAction(
                    title: "Off",
                    state: selectedSubtitleIndex == nil ? .on : .off
                ) { _ in
                    onSelectSubtitle(nil)
                }
            ]
            actions += subtitleStreams.map { stream in
                UIAction(
                    title: stream.displayTitle ?? stream.language ?? "Track \(stream.index)",
                    state: stream.index == selectedSubtitleIndex ? .on : .off
                ) { _ in
                    onSelectSubtitle(stream.index)
                }
            }
            menus.append(UIMenu(
                title: "Subtitles",
                image: UIImage(systemName: "captions.bubble"),
                options: [.singleSelection],
                children: actions
            ))
        }

        controller.transportBarCustomMenuItems = menus
        #endif
    }
}
#endif
