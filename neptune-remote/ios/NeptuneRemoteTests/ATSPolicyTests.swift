import XCTest
@testable import NeptuneRemote

/// Guards the App Transport Security configuration.
///
/// Background: Moonraker and the backend are plain HTTP over Tailscale, and
/// Tailscale hands out CGNAT addresses in 100.64.0.0/10. The app's Info.plist
/// declared `NSAllowsArbitraryLoads` but *also* `NSAllowsLocalNetworking`, and
/// Apple ignores the former - falling back to its default of NO - whenever the
/// latter is present. Every request to the Pi failed with
/// `NSURLErrorAppTransportSecurityRequiresSecureConnection` while Safari on the
/// same phone loaded the identical URL, because Safari is not bound by this
/// app's ATS policy.
final class ATSPolicyTests: XCTestCase {

    // MARK: - The override rule

    func testArbitraryLoadsAloneIsEffective() {
        let policy = ATSPolicy.policy(from: ["NSAllowsArbitraryLoads": true])
        XCTAssertTrue(policy.allowsArbitraryLoads)
        XCTAssertFalse(policy.isSilentlyDisabled)
        XCTAssertTrue(policy.overrides.isEmpty)
    }

    func testLocalNetworkingSilentlyDisablesArbitraryLoads() {
        let policy = ATSPolicy.policy(from: [
            "NSAllowsArbitraryLoads": true,
            "NSAllowsLocalNetworking": true
        ])
        XCTAssertTrue(policy.declaresArbitraryLoads)
        XCTAssertFalse(policy.allowsArbitraryLoads, "this is the exact bug that blocked HTTP over Tailscale")
        XCTAssertTrue(policy.isSilentlyDisabled)
        XCTAssertEqual(policy.overrides, ["NSAllowsLocalNetworking"])
    }

    /// The rule is about *presence*, not value: even `false` neutralises it.
    func testOverrideAppliesEvenWhenTheOverridingKeyIsFalse() {
        let policy = ATSPolicy.policy(from: [
            "NSAllowsArbitraryLoads": true,
            "NSAllowsArbitraryLoadsInWebContent": false
        ])
        XCTAssertFalse(policy.allowsArbitraryLoads)
    }

    func testMediaKeyAlsoOverrides() {
        let policy = ATSPolicy.policy(from: [
            "NSAllowsArbitraryLoads": true,
            "NSAllowsArbitraryLoadsForMedia": true
        ])
        XCTAssertFalse(policy.allowsArbitraryLoads)
    }

    func testMissingDictionaryBlocksPlainHTTP() {
        let policy = ATSPolicy.policy(from: nil)
        XCTAssertFalse(policy.allowsArbitraryLoads)
        XCTAssertFalse(policy.isSilentlyDisabled)
    }

    func testSummaryNamesTheOffendingKey() {
        let summary = ATSPolicy.policy(from: [
            "NSAllowsArbitraryLoads": true,
            "NSAllowsLocalNetworking": true
        ])
        XCTAssertTrue(summary.isSilentlyDisabled)

        let dictionary: [String: Any] = [
            "NSAllowsArbitraryLoads": true,
            "NSAllowsLocalNetworking": true
        ]
        let policy = ATSPolicy.policy(from: dictionary)
        XCTAssertEqual(policy.overrides, ["NSAllowsLocalNetworking"])
    }

    // MARK: - The shipped bundle

    /// The running bundle must actually permit plain HTTP, or the app cannot
    /// talk to the Raspberry Pi at all.
    func testShippedBundleAllowsPlainHTTP() throws {
        let bundle = Bundle(for: ATSPolicyTests.self)
        let candidates = [Bundle.main, bundle]
        guard let appBundle = candidates.first(where: {
            $0.object(forInfoDictionaryKey: "NSAppTransportSecurity") != nil
        }) else {
            throw XCTSkip("NSAppTransportSecurity not readable from the test bundle")
        }

        let policy = ATSPolicy.policy(in: appBundle)
        XCTAssertTrue(policy.declaresArbitraryLoads, "Info.plist must declare NSAllowsArbitraryLoads")
        XCTAssertEqual(
            policy.overrides, [],
            "these keys make iOS ignore NSAllowsArbitraryLoads and re-break HTTP over Tailscale"
        )
        XCTAssertTrue(policy.allowsArbitraryLoads)
    }

    // MARK: - Error mapping

    /// An ATS refusal must be reported as itself, not as a network failure -
    /// otherwise the user goes looking for a VPN or a dead Pi that is fine.
    func testATSErrorIsMappedAndNotRetryable() {
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorAppTransportSecurityRequiresSecureConnection
        )
        XCTAssertEqual(APIError.from(error, host: "100.78.2.66"), .blockedByATS)
        XCTAssertFalse(APIError.blockedByATS.isRetryable, "retrying cannot help; the binary must change")
        XCTAssertTrue(APIError.blockedByATS.isTransportFailure)
        XCTAssertEqual(APIError.blockedByATS.troubleshootingKey, "error.hint.ats_blocked")
    }

    /// Endpoint fallback must only trigger on transport failures. A 401 means
    /// Moonraker answered, and moving to another port would replace a precise
    /// error with a vague one.
    func testOnlyTransportFailuresJustifyTryingAnotherEndpoint() {
        XCTAssertTrue(APIError.timedOut.isTransportFailure)
        XCTAssertTrue(APIError.cannotConnect("pi").isTransportFailure)
        XCTAssertTrue(APIError.offline.isTransportFailure)

        XCTAssertFalse(APIError.unauthorized.isTransportFailure)
        XCTAssertFalse(APIError.notFound("server/info").isTransportFailure)
        XCTAssertFalse(APIError.server(status: 500, message: "").isTransportFailure)
        XCTAssertFalse(APIError.decoding("bad json").isTransportFailure)
    }
}
