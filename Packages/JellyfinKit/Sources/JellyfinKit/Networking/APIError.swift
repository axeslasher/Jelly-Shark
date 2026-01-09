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
            return "Invalid server URL"
        case .httpError(let statusCode):
            return "HTTP error: \(statusCode)"
        case .unauthorized:
            return "Invalid username or password"
        case .forbidden:
            return "Access denied"
        case .notFound:
            return "Resource not found"
        case .serverError(let statusCode):
            return "Server error: \(statusCode)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .decodingError(let message):
            return "Failed to parse response: \(message)"
        case .unsupportedServerVersion(let version):
            return "Server version \(version) is not supported. Minimum required: 10.8.0"
        case .notAuthenticated:
            return "Not authenticated. Please sign in."
        case .generic(let message):
            return message
        }
    }
}
