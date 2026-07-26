// Copyright 2026 Justin Lascelle
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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
            mediaSources: response.mediaSources?.compactMap { MediaSource(from: $0) } ?? [],
        )
    }
}

// MARK: - MediaSource Adapter

extension MediaSource {
    /// Create a MediaSource from the SDK's MediaSourceInfo
    init?(from info: JellyfinAPI.MediaSourceInfo) {
        guard let id = info.id else { return nil }

        let streams = info.mediaStreams?.map { MediaStreamInfo(from: $0) } ?? []
        let videoCodec = info.mediaStreams?.first { $0.type == .video }?.codec

        self.init(
            id: id,
            container: info.container,
            videoCodec: videoCodec,
            supportsDirectPlay: info.isSupportsDirectPlay ?? false,
            supportsDirectStream: info.isSupportsDirectStream ?? false,
            supportsTranscoding: info.isSupportsTranscoding ?? false,
            transcodingURL: info.transcodingURL,
            eTag: info.eTag,
            runTimeTicks: info.runTimeTicks.map(Int64.init),
            defaultAudioStreamIndex: info.defaultAudioStreamIndex,
            defaultSubtitleStreamIndex: info.defaultSubtitleStreamIndex,
            audioStreams: streams.filter { $0.type == .audio },
            subtitleStreams: streams.filter { $0.type == .subtitle },
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
            deliveryURL: stream.deliveryURL,
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
