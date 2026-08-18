@testable import Features
import Foundation
import JellyfinKit
import Testing

@Suite("Playback log sanitization")
struct PlaybackLogTests {
    @Test("Allowlisted remux errors retain their associated payloads")
    func retainsRemuxPayloads() {
        let malformed = PlaybackLog.error(MatroskaError.malformed("cluster timestamp missing"))
        let unsupported = PlaybackLog.error(MatroskaFMP4Remuxer.RemuxError.unsupportedAudioCodec("dts"))

        #expect(malformed == "MatroskaError.malformed(\"cluster timestamp missing\")")
        #expect(unsupported == "RemuxError.unsupportedAudioCodec(\"dts\")")
    }

    @Test("NSError userInfo cannot publish a credentialed failing URL")
    func excludesUserInfo() throws {
        let url = try #require(URL(string: "https://example.test/video.mkv?api_key=secret&static=true"))
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCancelled,
            userInfo: [
                NSLocalizedDescriptionKey: "cancelled",
                NSURLErrorFailingURLErrorKey: url,
                NSURLErrorFailingURLStringErrorKey: url.absoluteString,
            ],
        )

        let description = PlaybackLog.error(error)

        #expect(description == "NSURLErrorDomain -999: cancelled")
        #expect(!description.contains("secret"))
    }

    @Test("A URL-bearing localized description keeps its cause and loses the credential")
    func redactsURLBearingCause() {
        let error = NSError(
            domain: "CredentialedRequest",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "Failed https://example.test/video.mkv?api_key=secret&static=true"],
        )

        let description = PlaybackLog.error(error)

        #expect(description == "CredentialedRequest 7: Failed https://example.test/video.mkv?api_key=REDACTED&static=true")
        #expect(!description.contains("secret"))
    }

    @Test("Percent-encoded separators and terminators cannot smuggle a credential out")
    func redactsPercentEncodedCredentials() {
        let encoded = "url=https%3A%2F%2Fexample.test%2Fvideo.mkv%3Fapi_key%3Dsecret%26static%3Dtrue"

        let redacted = PlaybackLog.redacting(encoded)

        #expect(!redacted.contains("secret"))
        #expect(redacted.contains("api_key%3DREDACTED"))
        #expect(redacted.contains("static%3Dtrue"))
    }

    @Test("Unfamiliar credential parameter names redact by default")
    func redactsUnfamiliarCredentialNames() {
        let redacted = PlaybackLog.redacting("GET /Videos/1/stream?X-Emby-Token=abc&DeviceId=tv")

        #expect(redacted == "GET /Videos/1/stream?X-Emby-Token=REDACTED&DeviceId=tv")
    }

    @Test("Diagnostic query parameters survive a URL redaction")
    func keepsDiagnosticParameters() throws {
        let url = try #require(URL(
            string: "http://example.test:8096/Videos/1/master.m3u8?api_key=secret&static=true&AllowVideoStreamCopy=true",
        ))

        let logged = PlaybackLog.url(url)

        #expect(logged == "http://example.test:8096/Videos/1/master.m3u8?api_key=REDACTED&static=true&AllowVideoStreamCopy=true")
    }
}
