import DesignSystem
import JellyfinKit
import SwiftUI

/// Home's On Air Now shelf: one card per Live TV channel showing what is on,
/// each playing its channel on select. Draws nothing when the server has no
/// channels.
struct OnAirNowShelf: View {
    @Environment(AppSession.self) private var session
    @Environment(PlaybackPreferences.self) private var playbackPreferences

    let guide: LiveGuideModel
    /// Reports which card owns focus so Home can restore it. Nil in previews.
    var focusBinding: FocusState<ShelfFocusID?>.Binding?

    @State private var playingChannel: LiveChannel?

    var body: some View {
        // Stays in place while its player is up, whatever a reload says:
        // the player's cover hangs off this view and would go with it.
        if guide.hasChannels || playingChannel != nil {
            ContentShelf(
                LocalizedStringResource("liveTV.shelf.onAirNow", bundle: #bundle, comment: "Home shelf listing what each live TV channel is showing right now."),
                icon: "antenna.radiowaves.left.and.right",
            ) {
                ForEach(guide.channels) { channel in
                    LiveChannelCard(
                        channel: channel,
                        program: guide.currentProgram(for: channel),
                        now: guide.now,
                        secondLine: .channelAndEnd,
                        client: session.client,
                        focusBinding: focusBinding,
                        focusID: focusBinding == nil ? nil : ShelfFocusID(row: HomeShelfRowID.onAirNow, item: channel.id),
                        onPlay: { playingChannel = channel },
                    )
                }
            }
            .task {
                // A shelf of what is on now has to keep up with the clock.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    await guide.tick()
                }
            }
            // On the shelf rather than on Home: Home already presents the
            // library player from its own cover.
            .fullScreenCover(item: $playingChannel) { channel in
                if let client = session.client {
                    LivePlaybackView(
                        client: client,
                        channel: channel,
                        guide: guide,
                        streamingBitrateCap: playbackPreferences.streamingQuality.bitsPerSecond,
                    )
                }
            }
        }
    }
}

#if DEBUG
    private struct OnAirNowShelfPreview: View {
        var body: some View {
            OnAirNowShelf(guide: .preview())
        }
    }

    #Preview("Standard", traits: .featuresEnvironment(theme: .standard)) { OnAirNowShelfPreview() }
    #Preview("Horror", traits: .featuresEnvironment(theme: .horror)) { OnAirNowShelfPreview() }
    #Preview("Action", traits: .featuresEnvironment(theme: .action)) { OnAirNowShelfPreview() }
    #Preview("Video Store", traits: .featuresEnvironment(theme: .videoStore)) { OnAirNowShelfPreview() }
    #Preview("Sci-Fi", traits: .featuresEnvironment(theme: .sciFi)) { OnAirNowShelfPreview() }
#endif
