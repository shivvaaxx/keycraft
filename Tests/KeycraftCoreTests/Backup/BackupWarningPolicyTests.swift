import Foundation
import Testing
@testable import KeycraftCore

struct BackupWarningPolicyTests {
    private func entry(_ id: String, _ result: BackupResult) -> BackupEntry {
        BackupEntry(item: BackupItem(id: id, name: id, importance: .important) { nil }, result: result)
    }
    private func policy() -> BackupWarningPolicy {
        let suite = "keycraft.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return BackupWarningPolicy(defaults: defaults)
    }

    @Test func suppressionOfferedOnlyWhenEverythingMissingIsPermanent() {
        let firmware = entry("firmware", .notSupported("no"))
        let macros = entry("macros", .failed("timeout"))
        #expect(BackupWarningPolicy.canOfferSuppression(missing: [firmware]))
        #expect(!BackupWarningPolicy.canOfferSuppression(missing: [firmware, macros]))
        #expect(!BackupWarningPolicy.canOfferSuppression(missing: [macros]))
        #expect(!BackupWarningPolicy.canOfferSuppression(missing: []))
    }

    @Test func suppressedKeyboardStopsWarningOnlyForPermanentGaps() {
        let p = policy()
        let firmware = entry("firmware", .notSupported("no")), macros = entry("macros", .failed("timeout"))
        #expect(p.shouldWarn(missing: [firmware], vendorID: 0x4335, productID: 2))
        p.suppress(vendorID: 0x4335, productID: 2)
        #expect(!p.shouldWarn(missing: [firmware], vendorID: 0x4335, productID: 2))
        // a failure always warns, even for a suppressed keyboard
        #expect(p.shouldWarn(missing: [firmware, macros], vendorID: 0x4335, productID: 2))
        // suppression is per vid:pid
        #expect(p.shouldWarn(missing: [firmware], vendorID: 0x4335, productID: 3))
        // nothing missing, nothing to say
        #expect(!p.shouldWarn(missing: [], vendorID: 1, productID: 1))
    }
}
