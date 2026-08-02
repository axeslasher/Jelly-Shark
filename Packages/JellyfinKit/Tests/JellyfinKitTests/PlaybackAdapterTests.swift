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

@Suite("Version Facts")
struct VersionFactsTests {
    @Test("The adapter keeps the version facts and the video stream")
    func versionFactsMapping() throws {
        let info = JellyfinAPI.MediaSourceInfo(
            bitrate: 24_500_000,
            id: "source-1",
            mediaStreams: [
                JellyfinAPI.MediaStream(
                    bitDepth: 10,
                    bitRate: 22_000_000,
                    codec: "hevc",
                    height: 2160,
                    index: 0,
                    type: .video,
                    videoRangeType: .hdr10,
                    width: 3840,
                ),
                JellyfinAPI.MediaStream(codec: "aac", index: 1, type: .audio),
            ],
            name: "4K HDR",
            size: 42_000_000_000,
        )

        let source = try #require(MediaSource(from: info))

        #expect(source.name == "4K HDR")
        #expect(source.sizeBytes == 42_000_000_000)
        #expect(source.bitrate == 24_500_000)

        let video = try #require(source.videoStream)
        #expect(video.width == 3840)
        #expect(video.height == 2160)
        #expect(video.bitRate == 22_000_000)
        #expect(video.bitDepth == 10)
        #expect(video.videoRange == "HDR10")
        // The video stream is carried, not re-partitioned into the track lists.
        #expect(source.audioStreams.count == 1)
        #expect(source.subtitleStreams.isEmpty)
    }

    @Test("MediaItem carries its source list only when the fetch asked for it")
    func mediaItemSourceList() {
        let with = MediaItem(from: JellyfinAPI.BaseItemDto(
            id: "item-1",
            mediaSources: [
                JellyfinAPI.MediaSourceInfo(id: "source-1"),
                JellyfinAPI.MediaSourceInfo(id: "source-2"),
            ],
        ))
        #expect(with.mediaSources?.map(\.id) == ["source-1", "source-2"])

        let without = MediaItem(from: JellyfinAPI.BaseItemDto(id: "item-1"))
        #expect(without.mediaSources == nil)
    }
}

@Suite("Version Labeling")
struct VersionLabelingTests {
    @Test("Name leads; the technical facts become the detail line")
    func nameLed() {
        let source = MediaSource(
            id: "source-1",
            name: "Director's Cut",
            container: "mkv",
            videoCodec: "hevc",
            sizeBytes: 42_000_000_000,
            videoStream: MediaStreamInfo(
                index: 0,
                type: .video,
                width: 3840,
                height: 2160,
                videoRange: "Dolby Vision",
            ),
        )

        #expect(source.versionLabel == "Director's Cut")
        let size = Int64(42_000_000_000).formatted(.byteCount(style: .file))
        #expect(source.versionDetail == "4K · Dolby Vision · HEVC · MKV · \(size)")
    }

    @Test("Without a name the technical summary is the label, with no detail")
    func technicalFallback() {
        let source = MediaSource(
            id: "source-1",
            container: "mp4",
            videoCodec: "h264",
            videoStream: MediaStreamInfo(index: 0, type: .video, width: 1920, height: 1080),
        )

        #expect(source.versionLabel == "1080p · H.264 · MP4")
        #expect(source.versionDetail == nil)
    }

    @Test("A blank name falls through, and the label is never empty")
    func fallbacks() {
        let containerOnly = MediaSource(id: "source-1", name: "  ", container: "mkv")
        #expect(containerOnly.versionLabel == "MKV")
        #expect(containerOnly.versionDetail == nil)

        let bare = MediaSource(id: "source-1")
        #expect(bare.versionLabel == "Version")
    }
}
