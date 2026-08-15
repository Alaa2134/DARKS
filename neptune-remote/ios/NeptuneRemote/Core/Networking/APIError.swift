import Foundation

/// Every network failure the app can show, with a bilingual message.
enum APIError: LocalizedError, Equatable {
    case notConfigured
    case invalidURL
    case offline
    case timedOut
    case cannotConnect(String)
    /// iOS refused the request before it left the device because App Transport
    /// Security would not allow plain HTTP. Distinct from every other failure:
    /// nothing was ever sent, so the Pi is not at fault.
    case blockedByATS
    case unauthorized
    case notFound(String)
    case server(status: Int, message: String)
    case decoding(String)
    case moonraker(String)
    case unsafeOperation([String])
    case cancelled
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return L.t("error.not_configured")
        case .invalidURL:
            return L.t("error.invalid_url")
        case .offline:
            return L.t("error.offline")
        case .timedOut:
            return L.t("error.timeout")
        case .cannotConnect(let host):
            return L.t("error.cannot_connect") + " (\(host))"
        case .blockedByATS:
            return L.t("error.ats_blocked")
        case .unauthorized:
            return L.t("error.unauthorized")
        case .notFound(let what):
            return L.t("error.not_found") + (what.isEmpty ? "" : ": \(what)")
        case .server(let status, let message):
            return message.isEmpty ? "\(L.t("error.server")) (HTTP \(status))" : message
        case .decoding(let detail):
            return L.t("error.decoding") + (detail.isEmpty ? "" : ": \(detail)")
        case .moonraker(let message):
            return message.isEmpty ? L.t("error.moonraker") : message
        case .unsafeOperation(let blockers):
            return blockers.joined(separator: "\n")
        case .cancelled:
            return L.t("error.cancelled")
        case .unknown(let message):
            return message.isEmpty ? L.t("error.unknown") : message
        }
    }

    /// A short "what to check next" pointer, for the failures the user can
    /// actually act on. A timeout and a refused connection look identical in the
    /// UI otherwise, even though they mean very different things: nothing
    /// answered at all, versus the machine answered and turned us away.
    var troubleshootingKey: String? {
        switch self {
        case .timedOut:
            return "error.hint.timeout"
        case .cannotConnect:
            return "error.hint.cannot_connect"
        case .blockedByATS:
            return "error.hint.ats_blocked"
        case .offline:
            return "error.hint.offline"
        case .unauthorized:
            return "error.hint.unauthorized"
        case .notConfigured, .invalidURL:
            return "error.hint.not_configured"
        case .notFound, .server, .decoding, .moonraker, .unsafeOperation, .cancelled, .unknown:
            return nil
        }
    }

    /// `true` when the request never reached the server, so trying a different
    /// endpoint is worthwhile. An HTTP status - even 401 or 404 - means we found
    /// the server and should keep talking to it.
    var isTransportFailure: Bool {
        switch self {
        case .offline, .timedOut, .cannotConnect, .blockedByATS, .invalidURL, .notConfigured:
            return true
        case .unauthorized, .notFound, .server, .decoding, .moonraker,
             .unsafeOperation, .cancelled, .unknown:
            return false
        }
    }

    /// Whether offering a "Retry" button makes sense.
    var isRetryable: Bool {
        switch self {
        case .offline, .timedOut, .cannotConnect, .server, .moonraker, .unknown:
            return true
        // Retrying an ATS refusal just fails again: the app binary has to change.
        case .blockedByATS, .notConfigured, .invalidURL, .unauthorized, .notFound,
             .decoding, .unsafeOperation, .cancelled:
            return false
        }
    }

    static func from(_ error: Error, host: String = "") -> APIError {
        if let apiError = error as? APIError { return apiError }
        if error is CancellationError { return .cancelled }

        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return .unknown(error.localizedDescription)
        }
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
             NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff:
            return .offline
        case NSURLErrorTimedOut:
            return .timedOut
        case NSURLErrorCancelled:
            return .cancelled
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed, NSURLErrorSecureConnectionFailed:
            return .cannotConnect(host)
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return .blockedByATS
        default:
            return .unknown(nsError.localizedDescription)
        }
    }
}
