import Foundation
import Get
@testable import JellyfinKit
import Testing

/// Cancellations must reach callers as cancellations, not as a
/// String-carrying `networkError` (#300).
@Suite("Transport error mapping")
struct TransportErrorMappingTests {
    @Test("CancellationError passes through unchanged")
    func cancellationErrorPassesThrough() {
        let mapped = JellyfinClient.mapTransportError(CancellationError())
        #expect(mapped is CancellationError)
    }

    @Test("URLError(.cancelled) passes through unchanged")
    func urlCancelledPassesThrough() {
        let mapped = JellyfinClient.mapTransportError(URLError(.cancelled))
        #expect((mapped as? URLError)?.code == .cancelled)
    }

    @Test("Other URLErrors still map to networkError")
    func otherURLErrorMapsToNetworkError() {
        let mapped = JellyfinClient.mapTransportError(URLError(.notConnectedToInternet))
        guard case .networkError = mapped as? JellyfinKit.APIError else {
            Issue.record("Expected APIError.networkError, got \(mapped)")
            return
        }
    }

    @Test("A 401 status still maps to unauthorized")
    func unauthorizedStatusMapsToUnauthorized() {
        let mapped = JellyfinClient.mapTransportError(Get.APIError.unacceptableStatusCode(401))
        guard case .unauthorized = mapped as? JellyfinKit.APIError else {
            Issue.record("Expected APIError.unauthorized, got \(mapped)")
            return
        }
    }
}
