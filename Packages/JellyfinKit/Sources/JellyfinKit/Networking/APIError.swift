import Foundation

/// Errors that can occur when communicating with the Jellyfin API
public enum APIError: Error, Sendable {
    /// The server URL is invalid
    case invalidURL

    /// The request failed with a specific HTTP status code
    case httpError(statusCode: Int)

    /// Authentication failed (401)
    case unauthorized

    /// Access denied (403)
    case forbidden

    /// Resource not found (404)
    case notFound

    /// Server error (5xx)
    case serverError(statusCode: Int)

    /// Network connection failed
    case networkError(String)

    /// Failed to decode the response
    case decodingError(String)

    /// The server version is not supported
    case unsupportedServerVersion(String)

    /// No authenticated user
    case notAuthenticated

    /// Generic error with message
    case generic(String)
}

// MARK: - LocalizedError

extension APIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            String(localized: "error.api.invalidURL", bundle: #bundle,
                   comment: "Error shown when the server address can't be read as a web address.")
        case let .httpError(statusCode):
            String(localized: "error.api.http \(statusCode)", bundle: #bundle,
                   comment: "Error for an unexpected server response. The variable is the HTTP status code, such as 418.")
        case .unauthorized:
            String(localized: "error.api.unauthorized", bundle: #bundle,
                   comment: "Error shown when sign-in is rejected.")
        case .forbidden:
            String(localized: "error.api.forbidden", bundle: #bundle,
                   comment: "Error shown when the server refuses this user access.")
        case .notFound:
            String(localized: "error.api.notFound", bundle: #bundle,
                   comment: "Error shown when the server has no such item.")
        case let .serverError(statusCode):
            String(localized: "error.api.server \(statusCode)", bundle: #bundle,
                   comment: "Error when the server itself fails. The variable is the HTTP status code, such as 500.")
        case let .networkError(message):
            String(localized: "error.api.network \(message)", bundle: #bundle,
                   comment: "Error when the server can't be reached. The variable is the system's own description, usually already translated.")
        case let .decodingError(message):
            String(localized: "error.api.decoding \(message)", bundle: #bundle,
                   comment: "Error when the server's reply can't be read. The variable is a technical detail, often in English.")
        case let .unsupportedServerVersion(version):
            String(localized: "error.api.unsupportedServerVersion \(version) \(ServerInfo.minimumVersion)", bundle: #bundle,
                   comment: "Error when the server is too old. The first variable is the server's version, the second the oldest supported version; both look like 10.11.11.")
        case .notAuthenticated:
            String(localized: "error.api.notAuthenticated", bundle: #bundle,
                   comment: "Error shown when an action needs a signed-in user.")
        case let .generic(message):
            // Already a runtime message, not our copy.
            message
        }
    }
}
