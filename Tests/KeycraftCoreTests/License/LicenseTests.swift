import Testing
@testable import KeycraftCore

/// Vectors come from `node Scripts/licence.mjs vectors` (WebCrypto), so they prove Swift verifies what the server signs.
@Suite struct LicenseTests {
    let testKey = "6kpsY-KcUgq-9VB7Ey7F-ZVHdq6-vnuSQh7qaRRG0iw"
    let valid = "KC1.eyJwIjoia2V5Y3JhZnQiLCJ0IjoidHhuXzAxdGVzdHRlc3R0ZXN0dGVzdHRlc3R0ZXN0IiwiZSI6ImJ1eWVyQGV4YW1wbGUuY29tIiwiaSI6IjIwMjYtMTEtMTYifQ.6q779OHG0GPh8cjZhEWcpBxWuuFc_iDpBdnFtgev_jcuu5spoU0w8N0CtNS1MexfuEHBLLaWqSERRZAKtDouAQ"
    let wrongProduct = "KC1.eyJwIjoicmVlbCIsInQiOiJ0eG5fMDF0ZXN0dGVzdHRlc3R0ZXN0dGVzdHRlc3QiLCJlIjoiYnV5ZXJAZXhhbXBsZS5jb20iLCJpIjoiMjAyNi0xMS0xNiJ9.2RsWwzwXuhXWZYkFSDCI17EHSfwa8SgpRpAgQ58BkWvCmOETci_OJ5tkZ9wyd3luM7VPPpgvLHAe7XQ3T60nCg"
    let otherSigner = "KC1.eyJwIjoia2V5Y3JhZnQiLCJ0IjoidHhuXzAxdGVzdHRlc3R0ZXN0dGVzdHRlc3R0ZXN0IiwiZSI6ImJ1eWVyQGV4YW1wbGUuY29tIiwiaSI6IjIwMjYtMTEtMTYifQ.D2Mr6z0llIj9Lk-pp0vpOQjZ2o1vms2ubVpAvHj1odavkv_9C448EsH-NH7-r3OZFFzcf9UJ6WFBFBhfA5NAAA"

    func check(_ key: String, _ error: LicenseError, publicKey: String? = nil) {
        #expect(throws: error) { try Licensing.verify(key, publicKey: publicKey ?? testKey) }
    }

    @Test func validKey() throws {
        let expected = License(product: "keycraft", transaction: "txn_01testtesttesttesttesttest", email: "buyer@example.com", issued: "2026-11-16")
        #expect(try Licensing.verify(valid, publicKey: testKey) == expected)
        #expect(try Licensing.verify("  \n\(valid)\n ", publicKey: testKey) == expected)
    }

    @Test func rejectsBadKeys() {
        check(otherSigner, .badSignature)
        check(wrongProduct, .wrongProduct)
        var tampered = valid
        let i = tampered.index(tampered.startIndex, offsetBy: 10)
        tampered.replaceSubrange(i...i, with: tampered[i] == "A" ? "B" : "A")
        check(tampered, .badSignature)
        for bad in ["", "KC1.abc", "XX1.a.b", "KC1.!!!.???"] { check(bad, .malformed) }
    }

    @Test func testKeyNeverPassesAsProduction() {
        #expect(throws: LicenseError.badSignature) { try Licensing.verify(valid) }
    }
}
