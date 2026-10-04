import Combine
import Foundation

/// One place every store's failures end up, so none of them can be silent.
///
/// The app has fourteen stores and forty screens, and a screen only shows an
/// error if somebody remembered to wire its store's `lastError` to a banner.
/// A sweep found fifteen screens that run commands and display nothing at all
/// when those commands fail - the same shape as "I press print and nothing
/// happens", repeated across the app.
///
/// Fixing that screen by screen fixes today and not tomorrow: the next screen
/// added starts silent too. So every store reports here instead, and one
/// presenter at the root of the app shows whatever arrives.
///
/// This is a safety net, not a replacement. Screens that show their own error
/// inline - with a Retry button, in the context where it happened - keep doing
/// that, because a message next to the thing that failed is better than a
/// message at the bottom of the screen. The net exists for everywhere else.
@MainActor
final class ErrorSink: ObservableObject {
    @Published var latest: APIError?

    private var cancellables = Set<AnyCancellable>()

    /// Mirrors a store's error stream into the sink.
    ///
    /// Only failures travel: a store clearing its error means *that* store
    /// recovered, which says nothing about whichever error is currently on
    /// screen. The banner is dismissed by the person reading it, or replaced
    /// by the next failure.
    func observe<T: Publisher>(_ publisher: T) where T.Output == APIError?, T.Failure == Never {
        publisher
            .compactMap { $0 }
            .sink { [weak self] error in self?.latest = error }
            .store(in: &cancellables)
    }
}
