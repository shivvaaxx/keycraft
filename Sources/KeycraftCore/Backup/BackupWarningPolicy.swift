import Foundation

/// Decides when the "Unable to back up" alert appears. Items a keyboard can never back up (`.notSupported`,
/// e.g. firmware) may be silenced per keyboard; failures (timeouts, errors) always warn.
// @unchecked Sendable: UserDefaults is documented as thread-safe.
public struct BackupWarningPolicy: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The "Don't warn again" toggle is offered only when every missing item is permanently unsupported.
    public static func canOfferSuppression(missing: [BackupEntry]) -> Bool {
        !missing.isEmpty && missing.allSatisfy { $0.status == .notSupported }
    }

    public func shouldWarn(missing: [BackupEntry], vendorID: Int, productID: Int) -> Bool {
        guard !missing.isEmpty else { return false }
        return !(Self.canOfferSuppression(missing: missing) && isSuppressed(vendorID: vendorID, productID: productID))
    }

    public func isSuppressed(vendorID: Int, productID: Int) -> Bool { defaults.bool(forKey: Self.key(vendorID, productID)) }

    public func suppress(vendorID: Int, productID: Int) { defaults.set(true, forKey: Self.key(vendorID, productID)) }

    private static func key(_ vendorID: Int, _ productID: Int) -> String {
        "backupWarningSuppressed." + String(format: "%04x:%04x", vendorID, productID)
    }
}
