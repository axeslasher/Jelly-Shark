import Foundation
import JellyfinAPI
@testable import JellyfinKit
import Testing

@Suite("Playback Adapters")
struct PlaybackAdapterTests {
    @Test("MediaSource maps from MediaSourceInfo")
    func mediaSourceMapping() throws {
        let info = JellyfinAPI.MediaSourceInfo(
            container: "mkv",
            defaultAudioStreamIndex: 1,
            defaultSubtitleStreamIndex: 2,
            eTag: "etag-1",
            id: "source-1",
            runTimeTicks: 72_000_000_000,
            isSupportsDirectPlay: true,
            isSupportsDirectStream: true,
            isSupportsTranscoding: true,
            transcodingURL: "/videos/source-1/master.m3u8",
        )

        let source = try #require(MediaSource(from: info))

        #expect(source.id == "source-1")
        #expect(source.container == "mkv")
        #expect(source.supportsDirectPlay)
        #expect(source.supportsDirectStream)
        #expect(source.supportsTranscoding)
        #expect(source.eTag == "etag-1")
        #expect(source.runTimeTicks == 72_000_000_000)
        #expect(source.defaultAudioStreamIndex == 1)
        #expect(source.defaultSubtitleStreamIndex == 2)
        #expect(source.transcodingURL == "/videos/source-1/master.m3u8")
    }

    @Test("MediaSource requires an id")
    func mediaSourceRequiresId() {
        let info = JellyfinAPI.MediaSourceInfo(container: "mp4")
        #expect(MediaSource(from: info) == nil)
    }

    @Test("Media streams are partitioned by type")
    func streamPartitioning() throws {
        let info = JellyfinAPI.MediaSourceInfo(
            id: "source-1",
            mediaStreams: [
                JellyfinAPI.MediaStream(codec: "hevc", index: 0, type: .video),
                JellyfinAPI.MediaStream(codec: "aac", displayTitle: "English - AAC", index: 1, language: "eng", type: .audio),
                JellyfinAPI.MediaStream(codec: "ac3", index: 2, language: "fra", type: .audio),
                JellyfinAPI.MediaStream(
                    codec: "subrip",
                    index: 3,
                    isTextSubtitleStream: true,
                    language: "eng",
                    type: .subtitle,
                ),
            ],
        )

        let source = try #require(MediaSource(from: info))

        #expect(source.audioStreams.count == 2)
        #expect(source.subtitleStreams.count == 1)
        #expect(source.audioStreams[0].displayTitle == "English - AAC")
        #expect(source.audioStreams[0].index == 1)
        #expect(source.subtitleStreams[0].isTextSubtitleStream)
        #expect(source.subtitleStreams[0].type == .subtitle)
    }

    @Test("PlaybackSessionInfo maps from PlaybackInfoResponse")
    func sessionInfoMapping() {
        let response = JellyfinAPI.PlaybackInfoResponse(
            mediaSources: [
                JellyfinAPI.MediaSourceInfo(id: "source-1"),
                JellyfinAPI.MediaSourceInfo(id: "source-2"),
            ],
            playSessionID: "session-1",
        )

        let session = PlaybackSessionInfo(from: response)

        #expect(session.playSessionId == "session-1")
        #expect(session.mediaSources.count == 2)
        #expect(session.defaultMediaSource?.id == "source-1")
    }

    @Test("Sources without ids are dropped")
    func sourcesWithoutIdsDropped() {
        let response = JellyfinAPI.PlaybackInfoResponse(
            mediaSources: [
                JellyfinAPI.MediaSourceInfo(container: "mp4"),
                JellyfinAPI.MediaSourceInfo(id: "source-2"),
            ],
        )

        let session = PlaybackSessionInfo(from: response)

        #expect(session.mediaSources.count == 1)
        #expect(session.defaultMediaSource?.id == "source-2")
    }
}

@Suite("PlayMethod Adapter")
struct PlayMethodAdapterTests {
    @Test("Domain play methods map onto the SDK reporting enum")
    func playMethodMapping() {
        #expect(JellyfinAPI.PlayMethod(from: .directPlay) == .directPlay)
        #expect(JellyfinAPI.PlayMethod(from: .directStream) == .directStream)
        #expect(JellyfinAPI.PlayMethod(from: .transcode) == .transcode)
    }
}
