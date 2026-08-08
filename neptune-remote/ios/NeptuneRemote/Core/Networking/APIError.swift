import Foundation

/// Every network failure the app can show, with a bilingual message.
enum APIError: LocalizedError, Equatable {
    case notConfigured
    case invalidURL
    case offline
    case timedOut
    case cannotConnect(String)
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

    /// Whether offering a "Retry" button makes sense.
    var isRetryable: Bool {
        switch self {
        case .offline, .timedOut, .cannotConnect, .server, .moonraker, .unknown:
            return true
        case .notConfigured, .invalidURL, .unauthorized, .notFound, .decoding, .unsafeOperation, .cancelled:
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
        default:
            return .unknown(nsError.localizedDescription)
        }
    }
}
