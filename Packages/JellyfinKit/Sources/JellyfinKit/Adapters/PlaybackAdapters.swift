import Foundation
import JellyfinAPI

// MARK: - Playback Adapters
//
// Extensions that map Jellyfin SDK playback types (PlaybackInfoResponse,
// MediaSourceInfo, MediaStream) to our clean, app-specific types.

// MARK: - PlaybackSessionInfo Adapter

extension PlaybackSessionInfo {
    /// Create a PlaybackSessionInfo from the SDK's PlaybackInfoResponse
    init(from response: JellyfinAPI.PlaybackInfoResponse) {
        self.init(
            playSessionId: response.playSessionID,
            mediaSources: response.mediaSources?.compactMap { MediaSource(from: $0) } ?? []
        )
    }
}

// MARK: - MediaSource Adapter

extension MediaSource {
    /// Create a MediaSource from the SDK's MediaSourceInfo
    init?(from info: JellyfinAPI.MediaSourceInfo) {
        guard let id = info.id else { return nil }

        let streams = info.mediaStreams?.map { MediaStreamInfo(from: $0) } ?? []

        self.init(
            id: id,
            container: info.container,
            supportsDirectPlay: info.isSupportsDirectPlay ?? false,
            supportsDirectStream: info.isSupportsDirectStream ?? false,
            supportsTranscoding: info.isSupportsTranscoding ?? false,
            transcodingURL: info.transcodingURL,
            eTag: info.eTag,
            runTimeTicks: info.runTimeTicks.map(Int64.init),
            defaultAudioStreamIndex: info.defaultAudioStreamIndex,
            defaultSubtitleStreamIndex: info.defaultSubtitleStreamIndex,
            audioStreams: streams.filter { $0.type == .audio },
            subtitleStreams: streams.filter { $0.type == .subtitle }
        )
    }
}

// MARK: - PlayMethod Adapter

extension JellyfinAPI.PlayMethod {
    /// Map the domain play method onto the SDK's reporting enum
    init(from method: PlayMethod) {
        switch method {
        case .directPlay:
            self = .directPlay
        case .directStream:
            self = .directStream
        case .transcode:
            self = .transcode
        }
    }
}

// MARK: - MediaStreamInfo Adapter

extension MediaStreamInfo {
    /// Create a MediaStreamInfo from the SDK's MediaStream
    init(from stream: JellyfinAPI.MediaStream) {
        self.init(
            index: stream.index ?? 0,
            type: StreamType(from: stream.type),
            displayTitle: stream.displayTitle,
            language: stream.language,
            codec: stream.codec,
            isDefault: stream.isDefault ?? false,
            isExternal: stream.isExternal ?? false,
            isTextSubtitleStream: stream.isTextSubtitleStream ?? false,
            deliveryURL: stream.deliveryURL
        )
    }
}

extension MediaStreamInfo.StreamType {
    /// Create a StreamType from the SDK's MediaStreamType
    init(from type: JellyfinAPI.MediaStreamType?) {
        switch type {
        case .audio:
            self = .audio
        case .subtitle:
            self = .subtitle
        case .video:
            self = .video
        default:
            self = .unknown
        }
    }
}
