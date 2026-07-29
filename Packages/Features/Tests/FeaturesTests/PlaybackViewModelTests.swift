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

    /// Every suite member drives the view model through a mock engine; the
    /// engine comes back alongside so tests can assert on what reached it
    private func makePlayback(
        client: MockJellyfinClient,
        item: MediaItem,
        progressInterval: Duration = .seconds(10),
    ) -> (viewModel: PlaybackViewModel, engine: MockPlayerEngine) {
        let engine = MockPlayerEngine()
        let viewModel = PlaybackViewModel(
            client: client,
            item: item,
            engine: engine,
            progressInterval: progressInterval,
        )
        return (viewModel, engine)
    }

    @Test("start() transitions to playing and reports start")
    func startReachesPlaying() async {
        let client = MockJellyfinClient()
        let (viewModel, engine) = makePlayback(client: client, item: makeMovie())

        #expect(viewModel.state == .idle)
        await viewModel.start()

        #expect(viewModel.state == .playing)
        #expect(engine.isLoaded)
        #expect(engine.playCount == 1)
        #expect(viewModel.mediaSource?.id == "source-1")
        #expect(client.startReports.count == 1)
        #expect(client.startReports[0].itemId == "movie-1")
        #expect(client.startReports[0].positionTicks == 0)
    }

    @Test("start() requests playback info with the resume position")
    func startWithResumePosition() async {
        let client = MockJellyfinClient()
        let resumeTicks: Int64 = 6_000_000_000 // 10 minutes
        let (viewModel, engine) = makePlayback(client: client, item: makeMovie(resumeTicks: resumeTicks))

        await viewModel.start()

        #expect(client.playbackInfoRequests.count == 1)
        #expect(client.playbackInfoRequests[0].startTimeTicks == resumeTicks)
        #expect(client.startReports[0].positionTicks == resumeTicks)
        #expect(engine.resumeSeeks == [600])
    }

    @Test("start() failure surfaces as failed state")
    func startFailure() async {
        let client = MockJellyfinClient()
        client.playbackInfoResult = .failure(APIError.generic("Playback not possible"))
        let (viewModel, engine) = makePlayback(client: client, item: makeMovie())

        await viewModel.start()

        #expect(viewModel.state == .failed("Playback not possible"))
        #expect(engine.loadRequests.isEmpty)
        #expect(client.startReports.isEmpty)
    }

    @Test("Empty media sources surface as failed state")
    func emptyMediaSources() async {
        let client = MockJellyfinClient()
        client.playbackInfoResult = .success(PlaybackSessionInfo(playSessionId: "s", mediaSources: []))
        let (viewModel, _) = makePlayback(client: client, item: makeMovie())

        await viewModel.start()

        #expect(viewModel.state == .failed("No playable media sources for this item"))
    }

    @Test("stop() reports stopped, tears the engine down, and is idempotent")
    func stopReportsAndIsIdempotent() async {
        let client = MockJellyfinClient()
        let (viewModel, engine) = makePlayback(client: client, item: makeMovie())

        await viewModel.start()
        await viewModel.stop()
        await viewModel.stop()

        #expect(client.stopReports.count == 1)
        #expect(client.stopReports[0].itemId == "movie-1")
        #expect(engine.teardownCount == 1)
        #expect(!engine.isLoaded)
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
        let (viewModel, _) = makePlayback(
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
        let (viewModel, _) = makePlayback(client: client, item: makeMovie())

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
        let (viewModel, _) = makePlayback(client: client, item: makeMovie())

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

        let (viewModel, _) = makePlayback(client: client, item: episode)
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
        let (viewModel, _) = makePlayback(client: client, item: makeMovie())

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
        let (viewModel, _) = makePlayback(client: client, item: episode)

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
        let (viewModel, _) = makePlayback(client: client, item: episode)

        await viewModel.start()
        await viewModel.handlePlaybackEnded()
        viewModel.cancelAutoplay()

        #expect(viewModel.nextEpisode == nil)
        #expect(viewModel.state == .finished)
    }

    // MARK: - Engine Events

    @Test("A delivery-failure event fails the session but keeps it addressable")
    func deliveryFailureEventFailsSession() async {
        let client = MockJellyfinClient()
        let (viewModel, engine) = makePlayback(client: client, item: makeMovie())

        await viewModel.start()
        engine.send(.deliveryFailed(reason: "Cannot Open", cause: "player item status failed"))

        #expect(viewModel.state == .failed(PlaybackViewModel.deliveryFailureMessage(reason: "Cannot Open")))
        // failDelivery pauses rather than tears down: the session stays
        // diagnosable until Close runs stop()
        #expect(engine.pauseCount == 1)
        #expect(engine.teardownCount == 0)
        #expect(engine.isLoaded)
    }

    @Test("A played-to-end event queues the next episode")
    func playedToEndEventQueuesNextEpisode() async {
        let client = MockJellyfinClient()
        let next = MediaItem(id: "ep-2", name: "Episode 2", type: .episode, seriesId: "series-1")
        client.nextEpisodeResult = next
        let episode = MediaItem(id: "ep-1", name: "Episode 1", type: .episode, seriesId: "series-1")
        let (viewModel, engine) = makePlayback(client: client, item: episode)

        await viewModel.start()
        engine.send(.playedToEnd)
        await waitUntil { viewModel.nextEpisode != nil }

        #expect(viewModel.nextEpisode == next)
    }

    @Test("A native-picker subtitle change reconciles into app state")
    func mediaSelectionChangeReconciles() async {
        let client = MockJellyfinClient()
        stubSubtitledSource(on: client, directPlay: false)
        let (viewModel, engine) = makePlayback(client: client, item: makeMovie())

        await viewModel.start()
        #expect(viewModel.selectedSubtitleStreamIndex == nil)

        // The engine's legible options come in, then the viewer picks the
        // Spanish rendition in the native picker. (Spanish, not English:
        // the source also carries an English PGS stream, which makes the
        // English reverse-match ambiguous — the matcher refuses to guess.)
        engine.legibleOptions = [
            LegibleOption(position: 0, displayName: "English - Default - SUBRIP", languageTag: "en"),
            LegibleOption(position: 1, displayName: "Spanish - SUBRIP", languageTag: "es"),
        ]
        engine.send(.mediaSelectionOptionsLoaded)
        engine.selectedLegiblePosition = 1
        engine.send(.mediaSelectionChanged)
        await waitUntil { viewModel.selectedSubtitleStreamIndex != nil }

        #expect(viewModel.selectedSubtitleStreamIndex == 3)
        // Reconciliation is write-only: adopting the picker's choice must
        // never rebuild the stream it just switched in place
        #expect(engine.loadRequests.count == 1)
    }

    @Test("Selection-change events before options load are not reconciled")
    func mediaSelectionChangeBeforeOptionsLoadIsIgnored() async {
        let client = MockJellyfinClient()
        stubSubtitledSource(on: client, directPlay: false)
        let (viewModel, engine) = makePlayback(client: client, item: makeMovie())

        await viewModel.start()
        engine.legibleOptions = [
            LegibleOption(position: 0, displayName: "English - Default - SUBRIP", languageTag: "en"),
        ]
        engine.selectedLegiblePosition = 0
        // No .mediaSelectionOptionsLoaded — reconcile must stay disarmed
        engine.send(.mediaSelectionChanged)
        // Drain the event handler's task; there is no state change to wait on
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        #expect(viewModel.selectedSubtitleStreamIndex == nil)
    }

    // MARK: - Event Gates

    // The gates reproduce the timing at which the pre-seam view model
    // attached each observer, so no event class acts earlier than it used
    // to (#85). `MockPlayerEngine.onPlay` fires inside the window where
    // both are still closed.

    /// Drain the event handler's spawned tasks when there is no state
    /// change to wait on — a gate working means nothing happens
    private func drainEvents() async {
        for _ in 0 ..< 10 {
            await Task.yield()
        }
    }

    @Test("A delivery-failure event before the gate opens cannot half-fail the session")
    func deliveryFailureBeforeGateIsDropped() async {
        let client = MockJellyfinClient()
        let (viewModel, engine) = makePlayback(client: client, item: makeMovie())

        // No engine error, so the arm-time re-check finds nothing either
        engine.onPlay = { [weak engine] in
            engine?.send(.deliveryFailed(reason: nil, cause: "player item status failed"))
        }
        await viewModel.start()

        // Ungated, failDelivery would run here and pause the engine — and
        // then `state = .playing`, the very next line of beginPlayback,
        // would overwrite `.failed`. The session would be left with a
        // paused engine while its state claimed to be playing.
        #expect(viewModel.state == .playing)
        #expect(engine.pauseCount == 0)
    }

    @Test("The arm-time re-check surfaces a failure that landed while the gate was closed")
    func deliveryFailureInGapSurfacesViaErrorRecheck() async {
        let client = MockJellyfinClient()
        let (viewModel, engine) = makePlayback(client: client, item: makeMovie())

        engine.onPlay = { [weak engine] in
            // The engine's own error is what `armDeliveryFailureDetection`
            // reads back, standing in for the `.initial` KVO fire the
            // pre-seam view model got when it attached its observer here.
            // Note the residual gap: a failure with no error description
            // has nothing for the re-check to find, and only the
            // first-frame watchdog would catch it.
            engine?.currentErrorDescription = "Cannot Open"
            engine?.send(.deliveryFailed(reason: "Cannot Open", cause: "player item status failed"))
        }
        await viewModel.start()

        #expect(viewModel.state == .failed(PlaybackViewModel.deliveryFailureMessage(reason: "Cannot Open")))
        #expect(engine.pauseCount == 1)
    }

    @Test("A transport event before the gate opens emits no heartbeat")
    func transportChangeBeforeGateEmitsNoProgress() async {
        let client = MockJellyfinClient()
        let (viewModel, engine) = makePlayback(client: client, item: makeMovie())

        engine.onPlay = { [weak engine] in
            engine?.send(.transportStatusChanged)
        }
        await viewModel.start()
        await drainEvents()

        // The gate exists so the play() ramp cannot race a progress report
        // ahead of the start report the server needs first
        #expect(client.startReports.count == 1)
        #expect(client.progressReports.isEmpty)
    }

    @Test("A played-to-end event before the gate opens does not queue autoplay")
    func playedToEndBeforeGateIsDropped() async {
        let client = MockJellyfinClient()
        client.nextEpisodeResult = MediaItem(id: "ep-2", name: "Episode 2", type: .episode, seriesId: "series-1")
        let episode = MediaItem(id: "ep-1", name: "Episode 1", type: .episode, seriesId: "series-1")
        let (viewModel, engine) = makePlayback(client: client, item: episode)

        engine.onPlay = { [weak engine] in
            engine?.send(.playedToEnd)
        }
        await viewModel.start()
        await drainEvents()

        #expect(viewModel.nextEpisode == nil)
        #expect(viewModel.state == .playing)
    }

    @Test("Options-loaded is ungated, so reconciliation arms across the same window")
    func optionsLoadedIsNotGated() async {
        let client = MockJellyfinClient()
        stubSubtitledSource(on: client, directPlay: false)
        let (viewModel, engine) = makePlayback(client: client, item: makeMovie())

        // Deliberately asymmetric: this event only arms reconciliation, and
        // on a fast stream the engine can finish loading its groups before
        // the start report returns. Gating it would strand the session with
        // reconciliation permanently disarmed.
        engine.onPlay = { [weak engine] in
            engine?.send(.mediaSelectionOptionsLoaded)
        }
        await viewModel.start()

        engine.legibleOptions = [
            LegibleOption(position: 0, displayName: "English - Default - SUBRIP", languageTag: "en"),
            LegibleOption(position: 1, displayName: "Spanish - SUBRIP", languageTag: "es"),
        ]
        engine.selectedLegiblePosition = 1
        engine.send(.mediaSelectionChanged)
        await waitUntil { viewModel.selectedSubtitleStreamIndex != nil }

        #expect(viewModel.selectedSubtitleStreamIndex == 3)
    }

    // MARK: - Favorite Toggle

    @Test("toggleFavorite favorites, then unfavorites")
    func favoriteToggles() async {
        let client = MockJellyfinClient()
        let (viewModel, _) = makePlayback(client: client, item: makeMovie())

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
        let (viewModel, _) = makePlayback(client: client, item: item)

        #expect(viewModel.isFavorite == true)

        await viewModel.toggleFavorite()
        #expect(viewModel.isFavorite == false)
        #expect(client.userDataCalls.map(\.action) == ["unfavorite"])
    }

    @Test("toggleFavorite reverts the optimistic flip when the server call fails")
    func favoriteRevertsOnFailure() async {
        let client = MockJellyfinClient()
        client.userDataError = URLError(.notConnectedToInternet)
        let (viewModel, _) = makePlayback(client: client, item: makeMovie())

        await viewModel.toggleFavorite()

        #expect(client.userDataCalls.map(\.action) == ["favorite"])
        #expect(viewModel.isFavorite == false)
    }

    @Test("start() corrects a launching item whose favorite state went stale")
    func startCorrectsStaleFavoriteState() async {
        let client = MockJellyfinClient()
        // The state #189 reproduces: the detail page unfavorited the item and
        // flipped only its own optimistic override, so the item handed to the
        // player still claims favorite while the server disagrees.
        client.playbackExtrasResult = .success(PlaybackExtras(userData: UserData(isFavorite: false)))
        let staleItem = MediaItem(
            id: "movie-1",
            name: "Test Movie",
            type: .movie,
            userData: UserData(isFavorite: true),
        )
        let (viewModel, _) = makePlayback(client: client, item: staleItem)

        #expect(viewModel.isFavorite == true)

        await viewModel.start()

        #expect(viewModel.isFavorite == false)
        // Corrected from the extras fetch alone — no separate request
        #expect(client.playbackExtrasRequests == ["movie-1"])
        #expect(client.userDataCalls.isEmpty)
        await viewModel.stop()
    }

    @Test("start() keeps the fetched state when the extras carry no user data")
    func startKeepsFetchedStateWithoutExtrasUserData() async {
        let client = MockJellyfinClient()
        // Default stub: no user data in the response. The launching item is
        // then the only copy there is, so it must survive untouched.
        let item = MediaItem(
            id: "movie-1",
            name: "Test Movie",
            type: .movie,
            userData: UserData(isFavorite: true),
        )
        let (viewModel, _) = makePlayback(client: client, item: item)

        await viewModel.start()

        #expect(viewModel.isFavorite == true)
        await viewModel.stop()
    }

    @Test("A fresh position from the extras cannot move this session's resume seek")
    func startIgnoresExtrasPositionForResume() async {
        let client = MockJellyfinClient()
        client.playbackExtrasResult = .success(PlaybackExtras(
            userData: UserData(playbackPositionTicks: 600_000_000, isFavorite: true),
        ))
        let (viewModel, engine) = makePlayback(client: client, item: makeMovie(resumeTicks: 300_000_000))

        await viewModel.start()

        // Resume follows the launching item's 30s, not the extras' 60s: the
        // seek is committed before the extras land, and reporting a position
        // the player never sought to would be worse than a stale one.
        #expect(engine.resumeSeeks == [30])
        #expect(viewModel.isFavorite == true)
        await viewModel.stop()
    }

    @Test("A retry repeats the launch position rather than the extras' position")
    func retryKeepsLaunchResumePosition() async {
        let client = MockJellyfinClient()
        // The server's copy disagrees with the launching item — watched
        // further along on another client, say.
        client.playbackExtrasResult = .success(PlaybackExtras(
            userData: UserData(playbackPositionTicks: 600_000_000, isFavorite: true),
        ))
        let (viewModel, engine) = makePlayback(client: client, item: makeMovie(resumeTicks: 300_000_000))

        await viewModel.start()
        await viewModel.retry()

        // Both attempts seek to the launching item's 30s. `item` outlives a
        // single attempt, so taking the server's position when correcting the
        // favorite state would make Try Again land 60s in — somewhere the
        // first press did not go, and stale by then anyway.
        #expect(engine.resumeSeeks == [30, 30])
        // The state the correction is actually for still comes through
        #expect(viewModel.isFavorite == true)
        await viewModel.stop()
    }

    @Test("Autoplay drops the override so the next episode shows its own state")
    func favoriteOverrideClearsOnAutoplay() async {
        let client = MockJellyfinClient()
        let episode = MediaItem(id: "ep-1", name: "Episode 1", type: .episode, seriesId: "series-1")
        client.nextEpisodeResult = MediaItem(id: "ep-2", name: "Episode 2", type: .episode, seriesId: "series-1")
        let (viewModel, _) = makePlayback(client: client, item: episode)

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
        let (viewModel, engine) = makePlayback(client: client, item: makeMovie())

        await viewModel.start()

        #expect(viewModel.state == .playing)
        #expect(client.streamResolutions.count == 1)
        #expect(client.streamResolutions[0].playMethod == .directPlay)
        #expect(client.startReports.count == 1)
        #expect(client.startReports[0].playMethod == .directPlay)
        // Direct play has no renditions; the legible group is left alone
        #expect(engine.loadRequests[0].loadsLegibleOptions == false)
    }

    // MARK: - Trickplay

    private func makeTrickplayInfo() -> TrickplayInfo {
        TrickplayInfo(
            widthKey: 320, thumbnailWidth: 320, thumbnailHeight: 180,
            columns: 10, rows: 10, intervalMilliseconds: 10000, thumbnailCount: 60,
        )
    }

    @Test("start() requests the playback extras for the item")
    func startRequestsPlaybackExtras() async {
        let client = MockJellyfinClient()
        let (viewModel, engine) = makePlayback(client: client, item: makeMovie())

        await viewModel.start()

        #expect(client.playbackExtrasRequests == ["movie-1"])
        // No extras (the default stub) → the loopback server still
        // interposes: subtitle-playlist rewriting needs it on every HLS
        // session, trickplay or not
        #expect(engine.lastLoadedURL?.host() == "127.0.0.1")
        await viewModel.stop()
    }

    @Test("HLS playback with trickplay data interposes the loopback master")
    func trickplayInterposesMaster() async {
        let client = MockJellyfinClient()
        client.playbackExtrasResult = .success(PlaybackExtras(
            trickplay: TrickplayManifest(sources: ["source-1": [makeTrickplayInfo()]]),
        ))
        let (viewModel, engine) = makePlayback(client: client, item: makeMovie())

        await viewModel.start()

        #expect(viewModel.state == .playing)
        let url = engine.lastLoadedURL
        #expect(url?.host() == "127.0.0.1")
        #expect(url?.lastPathComponent == "master.m3u8")
        await viewModel.stop()
    }

    @Test("A playback-extras fetch failure still interposes, minus thumbnails")
    func playbackExtrasFailureDegrades() async {
        let client = MockJellyfinClient()
        client.playbackExtrasResult = .failure(APIError.generic("boom"))
        let (viewModel, engine) = makePlayback(client: client, item: makeMovie())

        await viewModel.start()

        #expect(viewModel.state == .playing)
        #expect(engine.lastLoadedURL?.host() == "127.0.0.1")
        await viewModel.stop()
    }

    @Test("Direct play never interposes, even with trickplay data")
    func directPlaySkipsTrickplay() async {
        let client = MockJellyfinClient()
        stubDirectPlaySource(on: client)
        client.playbackExtrasResult = .success(PlaybackExtras(
            trickplay: TrickplayManifest(sources: ["source-1": [makeTrickplayInfo()]]),
        ))
        let (viewModel, engine) = makePlayback(client: client, item: makeMovie())

        await viewModel.start()

        #expect(client.streamResolutions[0].playMethod == .directPlay)
        #expect(engine.lastLoadedURL?.host() == "example.com")
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
        let (viewModel, engine) = makePlayback(client: client, item: makeMovie())

        await viewModel.start()

        #expect(viewModel.state == .playing)
        #expect(engine.lastLoadedURL?.host() == "127.0.0.1")
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

    @Test("Chapters and runtime reach the engine as session metadata")
    func chaptersAttachMarkers() async throws {
        let client = MockJellyfinClient()
        client.playbackExtrasResult = .success(PlaybackExtras(chapters: makeChapters()))
        let (viewModel, engine) = makePlayback(client: client, item: makeMovie())

        await viewModel.start()

        // How the metadata becomes AVKit markers is the engine's business,
        // covered by AVFoundationPlayerEngineTests + PlayerMetadataFactoryTests
        let metadata = try #require(engine.lastMetadata)
        #expect(metadata.item.id == "movie-1")
        #expect(metadata.chapters.count == 2)
        #expect(metadata.durationSeconds == 7200)
    }

    @Test("A stream rebuild re-attaches metadata without refetching extras")
    func rebuildReattachesMarkers() async throws {
        let client = MockJellyfinClient()
        client.playbackExtrasResult = .success(PlaybackExtras(chapters: makeChapters()))
        let (viewModel, engine) = makePlayback(client: client, item: makeMovie())

        await viewModel.start()
        #expect(engine.loadRequests.count == 1)

        await viewModel.selectAudioStream(index: 2)

        #expect(engine.loadRequests.count == 2)
        #expect(engine.teardownCount == 1)
        #expect(client.playbackExtrasRequests == ["movie-1"])
        let metadata = try #require(engine.lastMetadata)
        #expect(metadata.chapters.count == 2)
    }

    @Test("Autoplaying the next episode refetches extras for the new item")
    func autoplayRefetchesExtras() async {
        let client = MockJellyfinClient()
        let episode = MediaItem(id: "ep-1", name: "Episode 1", type: .episode, seriesId: "series-1")
        client.nextEpisodeResult = MediaItem(id: "ep-2", name: "Episode 2", type: .episode, seriesId: "series-1")
        let (viewModel, _) = makePlayback(client: client, item: episode)

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
        let (viewModel, _) = makePlayback(client: client, item: makeMovie())

        await viewModel.start()

        #expect(viewModel.castMembers == [member])
    }

    @Test("A failed extras fetch falls back to the launching item's people")
    func castMembersFallBackToItem() async {
        let client = MockJellyfinClient()
        client.playbackExtrasResult = .failure(APIError.generic("boom"))
        let member = CastMember(id: "p2", name: "Actor", role: nil, kind: "Director", primaryImageTag: nil)
        let item = MediaItem(id: "movie-1", name: "Test Movie", type: .movie, people: [member])
        let (viewModel, _) = makePlayback(client: client, item: item)

        await viewModel.start()

        #expect(viewModel.castMembers == [member])
    }

    @Test("An item without runtime still plays, just without a duration")
    func missingRuntimeSkipsMarkers() async throws {
        let client = MockJellyfinClient()
        client.playbackExtrasResult = .success(PlaybackExtras(chapters: makeChapters()))
        let item = MediaItem(id: "movie-1", name: "No Runtime", type: .movie)
        let (viewModel, engine) = makePlayback(client: client, item: item)

        await viewModel.start()

        #expect(viewModel.state == .playing)
        let metadata = try #require(engine.lastMetadata)
        #expect(metadata.durationSeconds == nil)
    }

    @Test("The default mock source still transcodes (existing behavior preserved)")
    func incompatibleSourceTranscodes() async {
        let client = MockJellyfinClient()
        let (viewModel, _) = makePlayback(client: client, item: makeMovie())

        await viewModel.start()

        #expect(client.streamResolutions.count == 1)
        #expect(client.streamResolutions[0].playMethod == .transcode)
        #expect(client.startReports[0].playMethod == .transcode)
    }

    @Test("Selecting a subtitle on a direct session falls back to HLS; clearing returns to it")
    func subtitleSelectionLeavesDirectPlay() async {
        let client = MockJellyfinClient()
        stubDirectPlaySource(on: client)
        let (viewModel, _) = makePlayback(client: client, item: makeMovie())

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
        let (viewModel, engine) = makePlayback(client: client, item: makeMovie(resumeTicks: resumeTicks))

        await viewModel.start()

        #expect(client.streamResolutions[0].playMethod == .directPlay)
        #expect(client.startReports[0].positionTicks == resumeTicks)
        #expect(client.startReports[0].playMethod == .directPlay)
        #expect(engine.resumeSeeks == [600])
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
        let (viewModel, _) = makePlayback(client: client, item: makeMovie())

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
        let (viewModel, _) = makePlayback(client: client, item: makeMovie())

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
        let (viewModel, _) = makePlayback(client: client, item: makeMovie())

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
        let (viewModel, _) = makePlayback(client: client, item: episode)

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
        let (viewModel, _) = makePlayback(client: client, item: makeMovie())

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
        let (viewModel, engine) = makePlayback(client: client, item: makeMovie())

        await viewModel.start()
        #expect(engine.loadRequests.count == 1)

        await viewModel.selectSubtitleStream(index: 4)

        #expect(viewModel.selectedSubtitleStreamIndex == 4)
        #expect(client.playbackInfoRequests.count == 2)
        #expect(client.streamResolutions.count == 2)
        #expect(client.streamResolutions[1].parameters.subtitleStreamIndex == 4)
        #expect(client.startReports.count == 2)
        // The rebuild is a fresh load on a torn-down session, not an
        // in-place swap
        #expect(engine.loadRequests.count == 2)
        #expect(engine.teardownCount == 1)
    }
}
