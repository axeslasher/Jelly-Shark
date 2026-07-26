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
            "Invalid server URL"
        case let .httpError(statusCode):
            "HTTP error: \(statusCode)"
        case .unauthorized:
            "Invalid username or password"
        case .forbidden:
            "Access denied"
        case .notFound:
            "Resource not found"
        case let .serverError(statusCode):
            "Server error: \(statusCode)"
        case let .networkError(message):
            "Network error: \(message)"
        case let .decodingError(message):
            "Failed to parse response: \(message)"
        case let .unsupportedServerVersion(version):
            "Server version \(version) is not supported. Minimum required: 10.8.0"
        case .notAuthenticated:
            "Not authenticated. Please sign in."
        case let .generic(message):
            message
        }
    }
}
