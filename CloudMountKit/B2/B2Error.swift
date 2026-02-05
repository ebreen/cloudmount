//
//  B2Error.swift
//  CloudMountKit
//
//  B2 error types with retry and auth-expiry classification.
//  Maps HTTP status codes and B2 error codes to typed Swift errors.
//

import Foundation

// MARK: - B2Error

/// Errors originating from B2 API interactions.
public enum B2Error: Error, Sendable {
    /// 401 — bad_auth_token or expired_auth_token. Re-authorize with `b2_authorize_account`.
    case unauthorized(B2ErrorResponse)

    /// 400 — bad_request or other client errors.
    case badRequest(B2ErrorResponse)

    /// 403 — access_denied, cap_exceeded, etc.
    case forbidden(B2ErrorResponse)

    /// 404 — not_found.
    case notFound(B2ErrorResponse)

    /// 405 — method_not_allowed.
    case methodNotAllowed(B2ErrorResponse)

    /// 408 — request_timeout.
    case requestTimeout(B2ErrorResponse)

    /// 416 — range_not_satisfiable.
    case rangeNotSatisfiable(B2ErrorResponse)

    /// 429 — too_many_requests. Retry after the specified delay.
    case tooManyRequests(retryAfterSeconds: Int?, B2ErrorResponse)

    /// 500/503 — internal_error or service_unavailable. Transient; retry with backoff.
    case serverError(B2ErrorResponse)

    /// Network-level failure (no HTTP response received).
    case networkError(underlying: Error)

    /// Response body could not be decoded into the expected type.
    case decodingError(underlying: Error, data: Data?)

    /// A URL could not be constructed from the provided components.
    case invalidURL(String)

    // MARK: - Classification

    /// `true` when the error indicates the authorization token is invalid or expired.
    /// The caller should re-authorize with `b2_authorize_account`.
    public var isAuthExpired: Bool {
        switch self {
        case .unauthorized:
            return true
        default:
            return false
        }
    }

    /// `true` when the error is transient and the request may succeed on retry.
    /// Covers: 408 (timeout), 429 (rate-limit), 500/503 (server), and network errors.
    public var isRetryable: Bool {
        switch self {
        case .requestTimeout, .tooManyRequests, .serverError, .networkError:
            return true
        default:
            return false
        }
    }

    /// Suggested seconds to wait before retrying, or `nil` if not applicable.
    /// For 429 responses, uses the server-provided Retry-After header value.
    /// For other retryable errors, returns a default backoff hint.
    public var retryAfter: Int? {
        switch self {
        case .tooManyRequests(let seconds, _):
            return seconds ?? 1
        case .requestTimeout:
            return 1
        case .serverError:
            return 2
        case .networkError:
            return 1
        default:
            return nil
        }
    }

    // MARK: - Factory

    /// Create a `B2Error` from an HTTP response and its body data.
    ///
    /// Parses the B2 JSON error body `{status, code, message}` and maps the
    /// HTTP status code to the appropriate error case.
    ///
    /// - Parameters:
    ///   - httpResponse: The `HTTPURLResponse` from the failed request.
    ///   - data: The response body data (expected to be a JSON error object).
    ///   - retryAfterHeader: Value of the `Retry-After` response header, if present.
    /// - Returns: A typed `B2Error`.
    public static func from(
        httpResponse: HTTPURLResponse,
        data: Data,
        retryAfterHeader: String? = nil
    ) -> B2Error {
        let errorResponse: B2ErrorResponse
        do {
            errorResponse = try JSONDecoder.b2Decoder.decode(B2ErrorResponse.self, from: data)
        } catch {
            // If we can't decode the error body, fabricate one from the status code.
            errorResponse = B2ErrorResponse(
                status: httpResponse.statusCode,
                code: "unknown",
                message: "HTTP \(httpResponse.statusCode) — response body not decodable"
            )
        }

        switch httpResponse.statusCode {
        case 400:
            return .badRequest(errorResponse)
        case 401:
            return .unauthorized(errorResponse)
        case 403:
            return .forbidden(errorResponse)
        case 404:
            return .notFound(errorResponse)
        case 405:
            return .methodNotAllowed(errorResponse)
        case 408:
            return .requestTimeout(errorResponse)
        case 416:
            return .rangeNotSatisfiable(errorResponse)
        case 429:
            let seconds = retryAfterHeader.flatMap(Int.init)
            return .tooManyRequests(retryAfterSeconds: seconds, errorResponse)
        case 500...599:
            return .serverError(errorResponse)
        default:
            // Catch-all for unexpected status codes.
            return .serverError(errorResponse)
        }
    }
}

// MARK: - LocalizedError

extension B2Error: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthorized(let r):
            return "B2 unauthorized: \(r.message) [\(r.code)]"
        case .badRequest(let r):
            return "B2 bad request: \(r.message) [\(r.code)]"
        case .forbidden(let r):
            return "B2 forbidden: \(r.message) [\(r.code)]"
        case .notFound(let r):
            return "B2 not found: \(r.message) [\(r.code)]"
        case .methodNotAllowed(let r):
            return "B2 method not allowed: \(r.message) [\(r.code)]"
        case .requestTimeout(let r):
            return "B2 request timeout: \(r.message) [\(r.code)]"
        case .rangeNotSatisfiable(let r):
            return "B2 range not satisfiable: \(r.message) [\(r.code)]"
        case .tooManyRequests(_, let r):
            return "B2 rate limited: \(r.message) [\(r.code)]"
        case .serverError(let r):
            return "B2 server error: \(r.message) [\(r.code)]"
        case .networkError(let error):
            return "B2 network error: \(error.localizedDescription)"
        case .decodingError(let error, _):
            return "B2 decoding error: \(error.localizedDescription)"
        case .invalidURL(let url):
            return "B2 invalid URL: \(url)"
        }
    }
}
