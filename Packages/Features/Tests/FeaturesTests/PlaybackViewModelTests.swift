import AVFoundation
@testable import Features
import Foundation
import JellyfinKit
import Testing

@Suite("PlaybackViewModel")
@MainActor
struct PlaybackViewModelTests {
    private func makeMovie(resumeTicks: Int64? = nil) -> MediaItem {
        MediaItem(
            id: "movie-1",
            name: "Test Movie",
            type: .movie,
            runTimeTicks: 72_000_000_000,
            userData: resumeTicks.map { UserData(playbackPositionTicks: $0) },
        )
    }

    @Test("start() transitions to playing and reports start")
    func startReachesPlaying() async {
        let client = MockJellyfinClient()
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        #expect(viewModel.state == .idle)
        await viewModel.start()

        #expect(viewModel.state == .playing)
        #expect(viewModel.player != nil)
        #expect(viewModel.mediaSource?.id == "source-1")
        #expect(client.startReports.count == 1)
        #expect(client.startReports[0].itemId == "movie-1")
        #expect(client.startReports[0].positionTicks == 0)
    }

    @Test("start() requests playback info with the resume position")
    func startWithResumePosition() async {
        let client = MockJellyfinClient()
        let resumeTicks: Int64 = 6_000_000_000 // 10 minutes
        let viewModel = PlaybackViewModel(client: client, item: makeMovie(resumeTicks: resumeTicks))

        await viewModel.start()

        #expect(client.playbackInfoRequests.count == 1)
        #expect(client.playbackInfoRequests[0].startTimeTicks == resumeTicks)
        #expect(client.startReports[0].positionTicks == resumeTicks)
    }

    @Test("start() failure surfaces as failed state")
    func startFailure() async {
        let client = MockJellyfinClient()
        client.playbackInfoResult = .failure(APIError.generic("Playback not possible"))
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()

        #expect(viewModel.state == .failed("Playback not possible"))
        #expect(viewModel.player == nil)
        #expect(client.startReports.isEmpty)
    }

    @Test("Empty media sources surface as failed state")
    func emptyMediaSources() async {
        let client = MockJellyfinClient()
        client.playbackInfoResult = .success(PlaybackSessionInfo(playSessionId: "s", mediaSources: []))
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()

        #expect(viewModel.state == .failed("No playable media sources for this item"))
    }

    @Test("stop() reports stopped and is idempotent")
    func stopReportsAndIsIdempotent() async {
        let client = MockJellyfinClient()
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()
        await viewModel.stop()
        await viewModel.stop()

        #expect(client.stopReports.count == 1)
        #expect(client.stopReports[0].itemId == "movie-1")
        #expect(viewModel.player == nil)
    }

    /// Poll until the condition holds (bounded), so timer-driven assertions stay
    /// fast when healthy and tolerant when the machine is loaded. A fixed sleep
    /// would measure wall-clock the test does not control, which flakes on CI.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0 ..< 500 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Progress is reported periodically")
    func progressReporting() async {
        let client = MockJellyfinClient()
        let viewModel = PlaybackViewModel(
            client: client,
            item: makeMovie(),
            progressInterval: .milliseconds(50),
        )

        await viewModel.start()
        await waitUntil { client.progressReports.count >= 2 }
        await viewModel.stop()

        #expect(client.progressReports.count >= 2)
        #expect(client.progressReports.allSatisfy { $0.itemId == "movie-1" })
    }

    @Test("Track selection rebuilds the stream with the selected index")
    func trackSelectionRebuildsStream() async {
        let client = MockJellyfinClient()
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()
        await viewModel.selectSubtitleStream(index: 3)

        #expect(client.playbackInfoRequests.count == 2)
        #expect(client.playbackInfoRequests[1].subtitleStreamIndex == 3)
        #expect(viewModel.selectedSubtitleStreamIndex == 3)
        #expect(viewModel.state == .playing)
        #expect(client.startReports.count == 2)
    }

    @Test("Selecting the already-selected track is a no-op")
    func selectingSameTrackIsNoOp() async {
        let client = MockJellyfinClient()
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()
        await viewModel.selectSubtitleStream(index: nil)

        #expect(client.playbackInfoRequests.count == 1)
    }

    @Test("playNextEpisodeNow() closes the session and starts the next episode")
    func playNextEpisode() async {
        let client = MockJellyfinClient()
        let episode = MediaItem(id: "ep-1", name: "Episode 1", type: .episode, seriesId: "series-1")
        let next = MediaItem(id: "ep-2", name: "Episode 2", type: .episode, seriesId: "series-1")
        client.nextEpisodeResult = next

        let viewModel = PlaybackViewModel(client: client, item: episode)
        await viewModel.start()

        // Simulate end-of-item discovery having queued the next episode,
        // then the user (or countdown) advancing
        await viewModel.handlePlaybackEnded()
        #expect(viewModel.nextEpisode == next)

        await viewModel.playNextEpisodeNow()

        #expect(viewModel.item.id == "ep-2")
        #expect(viewModel.state == .playing)
        #expect(viewModel.nextEpisode == nil)
        #expect(client.stopReports.count == 1)
        #expect(client.stopReports[0].itemId == "ep-1")
        #expect(client.startReports.count == 2)
    }

    @Test("Movies finish without consulting next episode")
    func moviesDoNotAutoplay() async {
        let client = MockJellyfinClient()
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()
        await viewModel.handlePlaybackEnded()

        #expect(client.nextEpisodeRequests.isEmpty)
        #expect(viewModel.nextEpisode == nil)
        #expect(viewModel.state == .finished)
    }

    @Test("Last episode finishes without queueing autoplay")
    func lastEpisodeFinishes() async {
        let client = MockJellyfinClient()
        client.nextEpisodeResult = nil
        let episode = MediaItem(id: "ep-9", name: "Finale", type: .episode, seriesId: "series-1")
        let viewModel = PlaybackViewModel(client: client, item: episode)

        await viewModel.start()
        await viewModel.handlePlaybackEnded()

        #expect(client.nextEpisodeRequests == ["ep-9"])
        #expect(viewModel.nextEpisode == nil)
        #expect(viewModel.state == .finished)
    }

    @Test("cancelAutoplay() finishes the session")
    func cancelAutoplay() async {
        let client = MockJellyfinClient()
        client.nextEpisodeResult = MediaItem(id: "ep-2", name: "Episode 2", type: .episode, seriesId: "series-1")
        let episode = MediaItem(id: "ep-1", name: "Episode 1", type: .episode, seriesId: "series-1")
        let viewModel = PlaybackViewModel(client: client, item: episode)

        await viewModel.start()
        await viewModel.handlePlaybackEnded()
        viewModel.cancelAutoplay()

        #expect(viewModel.nextEpisode == nil)
        #expect(viewModel.state == .finished)
    }

    // MARK: - Favorite Toggle

    @Test("toggleFavorite favorites, then unfavorites")
    func favoriteToggles() async {
        let client = MockJellyfinClient()
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        #expect(viewModel.isFavorite == false)

        await viewModel.toggleFavorite()
        #expect(viewModel.isFavorite == true)

        await viewModel.toggleFavorite()
        #expect(viewModel.isFavorite == false)
        #expect(client.userDataCalls.map(\.action) == ["favorite", "unfavorite"])
        #expect(client.userDataCalls.allSatisfy { $0.itemId == "movie-1" })
    }

    @Test("An already-favorited item's toggle starts from its fetched state")
    func favoriteStartsFromFetchedState() async {
        let client = MockJellyfinClient()
        let item = MediaItem(
            id: "movie-1",
            name: "Test Movie",
            type: .movie,
            userData: UserData(isFavorite: true),
        )
        let viewModel = PlaybackViewModel(client: client, item: item)

        #expect(viewModel.isFavorite == true)

        await viewModel.toggleFavorite()
        #expect(viewModel.isFavorite == false)
        #expect(client.userDataCalls.map(\.action) == ["unfavorite"])
    }

    @Test("toggleFavorite reverts the optimistic flip when the server call fails")
    func favoriteRevertsOnFailure() async {
        let client = MockJellyfinClient()
        client.userDataError = URLError(.notConnectedToInternet)
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.toggleFavorite()

        #expect(client.userDataCalls.map(\.action) == ["favorite"])
        #expect(viewModel.isFavorite == false)
    }

    @Test("Autoplay drops the override so the next episode shows its own state")
    func favoriteOverrideClearsOnAutoplay() async {
        let client = MockJellyfinClient()
        let episode = MediaItem(id: "ep-1", name: "Episode 1", type: .episode, seriesId: "series-1")
        client.nextEpisodeResult = MediaItem(id: "ep-2", name: "Episode 2", type: .episode, seriesId: "series-1")
        let viewModel = PlaybackViewModel(client: client, item: episode)

        await viewModel.start()
        await viewModel.toggleFavorite()
        #expect(viewModel.isFavorite == true)

        await viewModel.handlePlaybackEnded()
        await viewModel.playNextEpisodeNow()

        #expect(viewModel.favoriteOverride == nil)
        #expect(viewModel.isFavorite == false)
        #expect(client.userDataCalls.map(\.itemId) == ["ep-1"])
    }

    // MARK: - Direct Play

    private func stubDirectPlaySource(on client: MockJellyfinClient) {
        client.playbackInfoResult = .success(
            PlaybackSessionInfo(
                playSessionId: "session-1",
                mediaSources: [
                    MediaSource(
                        id: "source-1",
                        container: "mp4",
                        supportsDirectPlay: true,
                        supportsDirectStream: true,
                        supportsTranscoding: true,
                    ),
                ],
            ),
        )
    }

    @Test("Direct-play-capable sources start and report direct play")
    func directPlayCapableSourceDirectPlays() async {
        let client = MockJellyfinClient()
        stubDirectPlaySource(on: client)
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()

        #expect(viewModel.state == .playing)
        #expect(client.streamResolutions.count == 1)
        #expect(client.streamResolutions[0].playMethod == .directPlay)
        #expect(client.startReports.count == 1)
        #expect(client.startReports[0].playMethod == .directPlay)
    }

    // MARK: - Trickplay

    private func makeTrickplayInfo() -> TrickplayInfo {
        TrickplayInfo(
            widthKey: 320, thumbnailWidth: 320, thumbnailHeight: 180,
            columns: 10, rows: 10, intervalMilliseconds: 10000, thumbnailCount: 60,
        )
    }

    private func assetURL(of viewModel: PlaybackViewModel) -> URL? {
        (viewModel.player?.currentItem?.asset as? AVURLAsset)?.url
    }

    @Test("start() requests the playback extras for the item")
    func startRequestsPlaybackExtras() async {
        let client = MockJellyfinClient()
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()

        #expect(client.playbackExtrasRequests == ["movie-1"])
        // No extras (the default stub) → the loopback server still
        // interposes: subtitle-playlist rewriting needs it on every HLS
        // session, trickplay or not
        #expect(assetURL(of: viewModel)?.host() == "127.0.0.1")
        await viewModel.stop()
    }

    @Test("HLS playback with trickplay data interposes the loopback master")
    func trickplayInterposesMaster() async {
        let client = MockJellyfinClient()
        client.playbackExtrasResult = .success(PlaybackExtras(
            trickplay: TrickplayManifest(sources: ["source-1": [makeTrickplayInfo()]]),
        ))
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()

        #expect(viewModel.state == .playing)
        let url = assetURL(of: viewModel)
        #expect(url?.host() == "127.0.0.1")
        #expect(url?.lastPathComponent == "master.m3u8")
        await viewModel.stop()
    }

    @Test("A playback-extras fetch failure still interposes, minus thumbnails")
    func playbackExtrasFailureDegrades() async {
        let client = MockJellyfinClient()
        client.playbackExtrasResult = .failure(APIError.generic("boom"))
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()

        #expect(viewModel.state == .playing)
        #expect(assetURL(of: viewModel)?.host() == "127.0.0.1")
        await viewModel.stop()
    }

    @Test("Direct play never interposes, even with trickplay data")
    func directPlaySkipsTrickplay() async {
        let client = MockJellyfinClient()
        stubDirectPlaySource(on: client)
        client.playbackExtrasResult = .success(PlaybackExtras(
            trickplay: TrickplayManifest(sources: ["source-1": [makeTrickplayInfo()]]),
        ))
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()

        #expect(client.streamResolutions[0].playMethod == .directPlay)
        #expect(assetURL(of: viewModel)?.host() == "example.com")
    }

    @Test("A manifest keyed to other media sources interposes without thumbnails")
    func mismatchedManifestSourceDegrades() async {
        let client = MockJellyfinClient()
        client.playbackExtrasResult = .success(PlaybackExtras(
            trickplay: TrickplayManifest(sources: [
                "other-source": [makeTrickplayInfo()],
                "another-source": [makeTrickplayInfo()],
            ]),
        ))
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()

        #expect(viewModel.state == .playing)
        #expect(assetURL(of: viewModel)?.host() == "127.0.0.1")
        await viewModel.stop()
    }

    // MARK: - Chapters & metadata

    private func makeChapters() -> [Chapter] {
        [
            Chapter(name: "One", startTicks: 0, imageIndex: 0),
            // 3600s into makeMovie()'s 7200s runtime
            Chapter(name: "Two", startTicks: 36_000_000_000, imageIndex: 1),
        ]
    }

    @Test("Chapters attach navigation markers and metadata to the player item")
    func chaptersAttachMarkers() async throws {
        let client = MockJellyfinClient()
        client.playbackExtrasResult = .success(PlaybackExtras(chapters: makeChapters()))
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()

        let playerItem = try #require(viewModel.player?.currentItem)
        #if os(tvOS)
            let group = try #require(playerItem.navigationMarkerGroups.first)
            #expect(group.title == nil)
            #expect(group.timedNavigationMarkers?.count == 2)
        #endif
        #expect(!playerItem.externalMetadata.isEmpty)
    }

    @Test("A stream rebuild re-attaches markers without refetching extras")
    func rebuildReattachesMarkers() async throws {
        let client = MockJellyfinClient()
        client.playbackExtrasResult = .success(PlaybackExtras(chapters: makeChapters()))
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()
        let originalItem = viewModel.player?.currentItem

        await viewModel.selectAudioStream(index: 2)

        let rebuiltItem = try #require(viewModel.player?.currentItem)
        #expect(rebuiltItem !== originalItem)
        #expect(client.playbackExtrasRequests == ["movie-1"])
        #if os(tvOS)
            #expect(rebuiltItem.navigationMarkerGroups.first?.timedNavigationMarkers?.count == 2)
        #endif
        #expect(!rebuiltItem.externalMetadata.isEmpty)
    }

    @Test("Autoplaying the next episode refetches extras for the new item")
    func autoplayRefetchesExtras() async {
        let client = MockJellyfinClient()
        let episode = MediaItem(id: "ep-1", name: "Episode 1", type: .episode, seriesId: "series-1")
        client.nextEpisodeResult = MediaItem(id: "ep-2", name: "Episode 2", type: .episode, seriesId: "series-1")
        let viewModel = PlaybackViewModel(client: client, item: episode)

        await viewModel.start()
        await viewModel.handlePlaybackEnded()
        await viewModel.playNextEpisodeNow()

        #expect(client.playbackExtrasRequests == ["ep-1", "ep-2"])
    }

    @Test("Cast members are published from the extras fetch")
    func castMembersFromExtras() async {
        let client = MockJellyfinClient()
        let member = CastMember(id: "p1", name: "Actor", role: "Lead", kind: "Actor", primaryImageTag: nil)
        client.playbackExtrasResult = .success(PlaybackExtras(people: [member]))
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()

        #expect(viewModel.castMembers == [member])
    }

    @Test("A failed extras fetch falls back to the launching item's people")
    func castMembersFallBackToItem() async {
        let client = MockJellyfinClient()
        client.playbackExtrasResult = .failure(APIError.generic("boom"))
        let member = CastMember(id: "p2", name: "Actor", role: nil, kind: "Director", primaryImageTag: nil)
        let item = MediaItem(id: "movie-1", name: "Test Movie", type: .movie, people: [member])
        let viewModel = PlaybackViewModel(client: client, item: item)

        await viewModel.start()

        #expect(viewModel.castMembers == [member])
    }

    @Test("An item without runtime still plays, just without markers")
    func missingRuntimeSkipsMarkers() async throws {
        let client = MockJellyfinClient()
        client.playbackExtrasResult = .success(PlaybackExtras(chapters: makeChapters()))
        let item = MediaItem(id: "movie-1", name: "No Runtime", type: .movie)
        let viewModel = PlaybackViewModel(client: client, item: item)

        await viewModel.start()

        #expect(viewModel.state == .playing)
        let playerItem = try #require(viewModel.player?.currentItem)
        #if os(tvOS)
            #expect(playerItem.navigationMarkerGroups.isEmpty)
        #endif
    }

    @Test("The default mock source still transcodes (existing behavior preserved)")
    func incompatibleSourceTranscodes() async {
        let client = MockJellyfinClient()
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()

        #expect(client.streamResolutions.count == 1)
        #expect(client.streamResolutions[0].playMethod == .transcode)
        #expect(client.startReports[0].playMethod == .transcode)
    }

    @Test("Selecting a subtitle on a direct session falls back to HLS; clearing returns to it")
    func subtitleSelectionLeavesDirectPlay() async {
        let client = MockJellyfinClient()
        stubDirectPlaySource(on: client)
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()
        #expect(client.startReports[0].playMethod == .directPlay)

        await viewModel.selectSubtitleStream(index: 3)
        #expect(viewModel.state == .playing)
        #expect(client.streamResolutions.count == 2)
        #expect(client.streamResolutions[1].playMethod == .directStream)
        #expect(client.streamResolutions[1].parameters.subtitleStreamIndex == 3)
        #expect(client.startReports[1].playMethod == .directStream)

        // Turning subtitles off rebuilds rather than deselecting in place:
        // staying put strands the session on the subtitle-shaped stream
        // (TS/H.264), and rebuilding wins back direct play of the original
        // file, which HLS was only ever a detour from.
        await viewModel.selectSubtitleStream(index: nil)
        #expect(viewModel.selectedSubtitleStreamIndex == nil)
        #expect(client.streamResolutions.count == 3)
        #expect(client.streamResolutions[2].playMethod == .directPlay)
        #expect(client.streamResolutions[2].parameters.subtitleStreamIndex == Int??.some(nil))
        #expect(client.startReports.count == 3)
        #expect(client.startReports[2].playMethod == .directPlay)
    }

    @Test("Resume works on a direct-play source")
    func resumeOnDirectPlay() async {
        let client = MockJellyfinClient()
        stubDirectPlaySource(on: client)
        let resumeTicks: Int64 = 6_000_000_000
        let viewModel = PlaybackViewModel(client: client, item: makeMovie(resumeTicks: resumeTicks))

        await viewModel.start()

        #expect(client.streamResolutions[0].playMethod == .directPlay)
        #expect(client.startReports[0].positionTicks == resumeTicks)
        #expect(client.startReports[0].playMethod == .directPlay)
    }

    // MARK: - Subtitle Selection

    private static let englishSrt = MediaStreamInfo(
        index: 2,
        type: .subtitle,
        displayTitle: "English - Default - SUBRIP",
        language: "eng",
        codec: "subrip",
        isDefault: true,
        isTextSubtitleStream: true,
    )
    private static let spanishSrt = MediaStreamInfo(
        index: 3,
        type: .subtitle,
        displayTitle: "Spanish - SUBRIP",
        language: "spa",
        codec: "subrip",
        isTextSubtitleStream: true,
    )
    private static let englishPgs = MediaStreamInfo(
        index: 4,
        type: .subtitle,
        displayTitle: "English - PGSSUB",
        language: "eng",
        codec: "pgssub",
        isTextSubtitleStream: false,
    )

    private func stubSubtitledSource(
        on client: MockJellyfinClient,
        directPlay: Bool = true,
        defaultSubtitleStreamIndex: Int? = nil,
    ) {
        client.playbackInfoResult = .success(
            PlaybackSessionInfo(
                playSessionId: "session-1",
                mediaSources: [
                    MediaSource(
                        id: "source-1",
                        container: "mp4",
                        supportsDirectPlay: directPlay,
                        supportsDirectStream: true,
                        supportsTranscoding: true,
                        defaultSubtitleStreamIndex: defaultSubtitleStreamIndex,
                        subtitleStreams: [Self.englishSrt, Self.spanishSrt, Self.englishPgs],
                    ),
                ],
            ),
        )
    }

    @Test("A text default is not seeded — AVKit owns text subtitles")
    func startLeavesTextDefaultToAVKit() async {
        let client = MockJellyfinClient()
        stubSubtitledSource(on: client, defaultSubtitleStreamIndex: 2)
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()

        // The master advertises the rendition DEFAULT=YES; AVKit plus the
        // viewer's system caption preference decide auto-on natively, and
        // reconciliation adopts whatever it picks
        #expect(viewModel.selectedSubtitleStreamIndex == nil)
        #expect(client.streamResolutions[0].parameters.subtitleStreamIndex == Int??.some(nil))
        #expect(client.streamResolutions[0].playMethod == .directPlay)
    }

    @Test("A burn-in default is seeded — only the app can honor it")
    func startSeedsBurnInDefault() async {
        let client = MockJellyfinClient()
        stubSubtitledSource(on: client, defaultSubtitleStreamIndex: 4)
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()

        #expect(viewModel.selectedSubtitleStreamIndex == 4)
        #expect(client.streamResolutions[0].parameters.subtitleStreamIndex == 4)
        // Burn-in composites server-side, which is always a transcode
        #expect(client.streamResolutions[0].playMethod == .transcode)
    }

    @Test("An explicit off is not re-seeded by rebuilds")
    func explicitOffSurvivesRebuild() async {
        let client = MockJellyfinClient()
        stubSubtitledSource(on: client, defaultSubtitleStreamIndex: 4)
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()
        await viewModel.selectSubtitleStream(index: nil)
        #expect(viewModel.selectedSubtitleStreamIndex == nil)

        // An audio change forces a rebuild; the explicit off must stick
        await viewModel.selectAudioStream(index: 9)

        #expect(viewModel.selectedSubtitleStreamIndex == nil)
        let lastResolution = client.streamResolutions.last
        #expect(lastResolution?.parameters.subtitleStreamIndex == Int??.some(nil))
    }

    @Test("Autoplay resets the selection so the next episode reseeds")
    func autoplayReseedsDefaultSubtitle() async {
        let client = MockJellyfinClient()
        stubSubtitledSource(on: client, defaultSubtitleStreamIndex: 4)
        let episode = MediaItem(id: "ep-1", name: "Episode 1", type: .episode, seriesId: "series-1")
        client.nextEpisodeResult = MediaItem(id: "ep-2", name: "Episode 2", type: .episode, seriesId: "series-1")
        let viewModel = PlaybackViewModel(client: client, item: episode)

        await viewModel.start()
        await viewModel.selectSubtitleStream(index: nil)
        await viewModel.handlePlaybackEnded()
        await viewModel.playNextEpisodeNow()

        #expect(viewModel.selectedSubtitleStreamIndex == 4)
    }

    @Test("Selecting an image subtitle transcodes for burn-in and rebuilds out of it")
    func imageSubtitleBurnInTransitions() async {
        let client = MockJellyfinClient()
        stubSubtitledSource(on: client)
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()
        #expect(client.startReports[0].playMethod == .directPlay)

        await viewModel.selectSubtitleStream(index: 4)
        #expect(client.streamResolutions.count == 2)
        #expect(client.streamResolutions[1].playMethod == .transcode)
        #expect(client.startReports[1].playMethod == .transcode)

        // Removing a burned-in track requires another rebuild — the video
        // itself has the subtitles composited in
        await viewModel.selectSubtitleStream(index: nil)
        #expect(client.streamResolutions.count == 3)
        #expect(client.streamResolutions[2].playMethod == .directPlay)
        #expect(client.startReports[2].playMethod == .directPlay)
    }

    @Test("Every app-menu subtitle change rebuilds the stream")
    func appMenuSubtitleChangesRebuild() async {
        // Post-#90 the app's menu carries only burn-in tracks, and burning
        // a track in or out of the video is always a server-side re-encode.
        // There is no in-place path left — and none may be added that calls
        // select(nil) on the legible group, which latches AVKit's subtitle
        // display off process-wide (#91).
        let client = MockJellyfinClient()
        stubSubtitledSource(on: client, directPlay: false, defaultSubtitleStreamIndex: nil)
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()
        let playerBefore = viewModel.player

        await viewModel.selectSubtitleStream(index: 4)

        #expect(viewModel.selectedSubtitleStreamIndex == 4)
        #expect(client.playbackInfoRequests.count == 2)
        #expect(client.streamResolutions.count == 2)
        #expect(client.streamResolutions[1].parameters.subtitleStreamIndex == 4)
        #expect(client.startReports.count == 2)
        #expect(viewModel.player !== playerBefore)
    }
}
