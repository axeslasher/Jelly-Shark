import Foundation
import JellyfinKit

/// `MatroskaByteSource` over HTTP `Range` requests against Jellyfin's
/// `static=true` endpoint — verified to answer 206 with a correct
/// `Content-Range` at arbitrary offsets (docs/PLAYBACK_MATRIX.md). The
/// demuxer indexes a tens-of-GB source through this in a few MB of reads.
struct RangedHTTPByteSource: MatroskaByteSource {
    let url: URL
    let length: UInt64
    private let session: URLSession

    enum SourceError: Error {
        /// The origin ignored `Range` — the remux delivery is impossible.
        case rangeNotSupported
        case badResponse(Int)
    }

    /// Probe the origin with a 1-byte range to learn the total size and
    /// prove `Range` is honoured before any machinery is stood up.
    static func probe(url: URL, session: URLSession = .shared) async throws -> RangedHTTPByteSource {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.badResponse(0)
        }
        // Content-Range: bytes 0-0/25021928706 — the total is the authority.
        guard http.statusCode == 206,
              let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
              let totalText = contentRange.split(separator: "/").last,
              let total = UInt64(totalText)
        else {
            throw http.statusCode == 206 ? SourceError.badResponse(http.statusCode) : SourceError.rangeNotSupported
        }
        return RangedHTTPByteSource(url: url, length: total, session: session)
    }

    func read(at offset: UInt64, count: Int) async throws -> Data {
        guard count > 0, offset < length else { return Data() }
        let end = min(offset + UInt64(count), length) - 1
        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
            throw SourceError.rangeNotSupported
        }
        return data
    }
}
