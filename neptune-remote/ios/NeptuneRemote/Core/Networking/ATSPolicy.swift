import Foundation

/// Reads the running app's App Transport Security policy out of its own bundle.
///
/// This exists because an ATS misconfiguration is invisible at the call site: a
/// blocked request looks like a network failure, so the user goes hunting for a
/// VPN or a dead Raspberry Pi that is in fact perfectly healthy. The connection
/// test asks this type first and, if plain HTTP cannot possibly work, says so
/// instead of blaming the network.
///
/// The trap it guards against is Apple's override rule: `NSAllowsArbitraryLoads`
/// is ignored, and treated as `NO`, whenever `NSAllowsLocalNetworking`,
/// `NSAllowsArbitraryLoadsInWebContent` or `NSAllowsArbitraryLoadsForMedia` is
/// also present in the Info.plist. A plist can therefore say `true` in plain
/// sight and still block every `http://` request.
enum ATSPolicy {

    /// Keys whose mere presence disables `NSAllowsArbitraryLoads` on iOS 10+.
    static let overridingKeys = [
        "NSAllowsLocalNetworking",
        "NSAllowsArbitraryLoadsInWebContent",
        "NSAllowsArbitraryLoadsForMedia"
    ]

    struct Policy: Equatable {
        /// The literal value written in the Info.plist.
        var declaresArbitraryLoads: Bool
        /// Keys present that make the system ignore the declaration above.
        var overrides: [String]

        /// What the system will actually do, as opposed to what the plist says.
        var allowsArbitraryLoads: Bool { declaresArbitraryLoads && overrides.isEmpty }

        /// The declaration is present but neutralised - the failure mode this
        /// type exists to catch.
        var isSilentlyDisabled: Bool { declaresArbitraryLoads && !overrides.isEmpty }
    }

    static func policy(in bundle: Bundle = .main) -> Policy {
        let dictionary = bundle.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]
        return policy(from: dictionary)
    }

    static func policy(from dictionary: [String: Any]?) -> Policy {
        guard let dictionary else {
            return Policy(declaresArbitraryLoads: false, overrides: [])
        }
        let declared = (dictionary["NSAllowsArbitraryLoads"] as? Bool) ?? false
        let overrides = overridingKeys.filter { dictionary[$0] != nil }
        return Policy(declaresArbitraryLoads: declared, overrides: overrides)
    }

    /// `true` when this build can reach a plain-HTTP host such as the Pi.
    static var allowsPlainHTTP: Bool { policy().allowsArbitraryLoads }

    /// A line for the diagnostics section, naming the offending keys when the
    /// policy has been silently disabled.
    static func summary(in bundle: Bundle = .main) -> String {
        let policy = policy(in: bundle)
        if policy.allowsArbitraryLoads {
            return "NSAllowsArbitraryLoads = YES"
        }
        if policy.isSilentlyDisabled {
            return "NSAllowsArbitraryLoads = YES (ignored: \(policy.overrides.joined(separator: ", ")))"
        }
        return "NSAllowsArbitraryLoads = NO"
    }
}
