import Foundation
import os
import Testing
@testable import KeycraftCore

@Suite struct GitHubSharingTests {
    private static let owner = "shivvaaxx", repo = "keycraft-keyboards"
    private let definition = try! fixture("v3_gh60_satan_satan.json")

    private func sharing(_ net: StubNetwork, token: String? = "tok123", sleeps: OSAllocatedUnfairLock<[Int]>? = nil,
                         store: MemoryTokenStore? = nil) throws -> GitHubSharing {
        let made = GitHubSharing(clientID: "client", repo: (Self.owner, Self.repo), session: net.session,
                                 tokens: store ?? MemoryTokenStore(token), appVersion: "9.9",
                                 sleep: { d in sleeps?.withLock { $0.append(Int(d.components.seconds)) } })
        return try #require(made)
    }

    private func submission(name: String = "GH60 Satan", maker: String = "Geekhack") throws -> Submission {
        try GitHubSharing.prepare(definition: definition, name: name, maker: maker)
    }

    /// A GitHub that behaves for a signed-in `login`; `pulls` answers the POST that opens the pull request.
    private func github(login: String = "alice", forkChecks: Int = 1, existingBranch: Bool = false,
                        pulls: @escaping @Sendable (StubRequest) -> StubReply = { _ in StubReply(201, ["html_url": "https://github.com/shivvaaxx/keycraft-keyboards/pull/7"]) }) -> StubNetwork {
        let forkReads = OSAllocatedUnfairLock(initialState: 0)
        return StubNetwork { r in
            switch (r.method, r.url.path()) {
            case ("GET", "/user"): return StubReply(200, ["login": login])
            case ("POST", "/repos/shivvaaxx/keycraft-keyboards/forks"): return StubReply(202, ["name": "keycraft-keyboards", "owner": ["login": login]])
            case ("GET", "/repos/\(login)/keycraft-keyboards") where login != Self.owner:
                return forkReads.withLock { $0 += 1; return $0 } > forkChecks ? StubReply(200, ["name": "keycraft-keyboards"]) : StubReply(404, ["message": "Not Found"])
            case ("GET", "/repos/shivvaaxx/keycraft-keyboards"): return StubReply(200, ["default_branch": "main"])
            case ("GET", "/repos/shivvaaxx/keycraft-keyboards/git/ref/heads/main"): return StubReply(200, ["object": ["sha": "abc123"]])
            case ("POST", "/repos/\(login)/keycraft-keyboards/git/refs"):
                return existingBranch ? StubReply(422, ["message": "Reference already exists"]) : StubReply(201)
            case ("GET", _) where r.url.path().contains("/contents/"): return StubReply(200, ["sha": "filesha"])
            case ("PUT", _) where r.url.path().contains("/contents/"): return StubReply(201)
            case ("POST", "/repos/shivvaaxx/keycraft-keyboards/pulls"): return pulls(r)
            case ("GET", "/repos/shivvaaxx/keycraft-keyboards/pulls"):
                return StubReply(200, [["html_url": "https://github.com/shivvaaxx/keycraft-keyboards/pull/3"]])
            default: return StubReply(404, ["message": "unexpected \(r.method) \(r.url.path())"])
            }
        }
    }

    // MARK: Sign in

    private func deviceFlow(_ raw: [[String: Any]]) -> StubNetwork {
        let answers = raw.map { StubReply(200, $0) }
        let polls = OSAllocatedUnfairLock(initialState: 0)
        return StubNetwork { r in
            switch r.url.path() {
            case "/login/device/code":
                return StubReply(200, ["device_code": "dev", "user_code": "ABCD-1234", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 5])
            case "/login/oauth/access_token":
                let i = polls.withLock { $0 += 1; return $0 - 1 }
                return answers[min(i, answers.count - 1)]
            default: return StubReply(404)
            }
        }
    }

    @Test func deviceFlowHonoursSlowDownAndStoresTheToken() async throws {
        let net = deviceFlow([["error": "authorization_pending"], ["error": "slow_down", "interval": 10], ["access_token": "gho_secret", "token_type": "bearer"]])
        let sleeps = OSAllocatedUnfairLock<[Int]>(initialState: [])
        let tokens = MemoryTokenStore()
        let s = try sharing(net, token: nil, sleeps: sleeps, store: tokens)
        let code = try await s.requestDeviceCode()
        #expect(code.userCode == "ABCD-1234" && code.verificationURL.absoluteString == "https://github.com/login/device")
        try await s.completeSignIn(code)
        #expect(sleeps.withLock { $0 } == [5, 5, 10])   // slow_down raised the interval for the next poll
        #expect(tokens.read() == "gho_secret" && s.isSignedIn)
        let start = try #require(net.requests.first)
        #expect(start.body == Data("client_id=client&scope=public_repo".utf8))
        #expect(!net.requests.contains { $0.headers["Authorization"] != nil })   // no secret, no token while signing in
        s.signOut()
        #expect(tokens.read() == nil)
    }

    @Test func deviceFlowFailuresAreNamed() async throws {
        for (answer, expected) in [("expired_token", SharingError.signInExpired), ("access_denied", .signInDenied)] {
            let s = try sharing(deviceFlow([["error": answer]]), token: nil)
            let code = try await s.requestDeviceCode()
            await #expect(throws: expected) { try await s.completeSignIn(code) }
            #expect(!s.isSignedIn)
        }
        let never = try sharing(deviceFlow([["error": "authorization_pending"]]), token: nil)   // never approved: the local clock runs out
        let code = try await never.requestDeviceCode()
        await #expect(throws: SharingError.signInExpired) { try await never.completeSignIn(code) }
    }

    @Test func notConfiguredMeansNoSharing() {
        #expect(GitHubSharing(clientID: nil, repo: (Self.owner, Self.repo)) == nil)
        #expect(GitHubSharing(clientID: "x", repo: nil) == nil)
    }

    // MARK: Share

    @Test func fullFlowForksBranchesCommitsAndOpensAPullRequest() async throws {
        let net = github(forkChecks: 1)
        let sleeps = OSAllocatedUnfairLock<[Int]>(initialState: [])
        let sub = try submission()
        let url = try await sharing(net, sleeps: sleeps).share(sub)
        #expect(url.absoluteString == "https://github.com/shivvaaxx/keycraft-keyboards/pull/7")
        #expect(sleeps.withLock { $0 } == [2])   // the fork wasn't there on the first check
        #expect(net.labels == [
            "GET api.github.com/user",
            "POST api.github.com/repos/shivvaaxx/keycraft-keyboards/forks",
            "GET api.github.com/repos/alice/keycraft-keyboards",
            "GET api.github.com/repos/alice/keycraft-keyboards",
            "GET api.github.com/repos/shivvaaxx/keycraft-keyboards",
            "GET api.github.com/repos/shivvaaxx/keycraft-keyboards/git/ref/heads/main",
            "POST api.github.com/repos/alice/keycraft-keyboards/git/refs",
            "PUT api.github.com/repos/alice/keycraft-keyboards/contents/keyboards/geekhack/gh60-satan.json",
            "POST api.github.com/repos/shivvaaxx/keycraft-keyboards/pulls",
        ])
        #expect(net.requests.allSatisfy { $0.headers["Authorization"] == "Bearer tok123" })
        let r = net.requests
        #expect(r[6].json?["ref"] as? String == "refs/heads/add-geekhack-gh60-satan-43350002" && r[6].json?["sha"] as? String == "abc123")
        let put = try #require(r[7].json)
        #expect(Set(put.keys) == ["message", "content", "branch"])   // nothing but the file, its message and the branch
        #expect(put["message"] as? String == "Add GH60 Satan (4335:0002)")
        #expect(Data(base64Encoded: put["content"] as? String ?? "") == definition)
        let pr = try #require(r[8].json)
        #expect(pr["head"] as? String == "alice:add-geekhack-gh60-satan-43350002" && pr["base"] as? String == "main")
        #expect((pr["body"] as? String)?.contains("4335:0002") == true && (pr["body"] as? String)?.contains("Submitted from Keycraft 9.9") == true)
    }

    @Test func existingPullRequestReturnsItsURL() async throws {
        let net = github(pulls: { _ in StubReply(422, ["message": "A pull request already exists for alice:add-geekhack-gh60-satan-43350002."]) })
        let url = try await sharing(net).share(submission())
        #expect(url.absoluteString == "https://github.com/shivvaaxx/keycraft-keyboards/pull/3")
        let list = try #require(net.requests.last)
        #expect(list.method == "GET" && list.url.query()?.contains("head=alice:add-geekhack") == true || list.url.absoluteString.contains("head=alice%3Aadd-geekhack"))
    }

    @Test func retryReusesTheBranchAndUpdatesTheFile() async throws {
        let net = github(forkChecks: 0, existingBranch: true)
        _ = try await sharing(net).share(submission())
        let put = try #require(net.requests.first { $0.method == "PUT" }?.json)
        #expect(put["sha"] as? String == "filesha")   // the file from the earlier try is replaced, not rejected
    }

    @Test func theRepoOwnerPushesABranchWithoutForking() async throws {
        let net = github(login: "shivvaaxx")
        _ = try await sharing(net).share(submission())
        #expect(!net.labels.contains { $0.contains("/forks") })
        let pr = try #require(net.requests.last { $0.method == "POST" }?.json)
        #expect(pr["head"] as? String == "shivvaaxx:add-geekhack-gh60-satan-43350002")
    }

    @Test func signedOutAndRevokedTokensAreHandled() async throws {
        await #expect(throws: SharingError.notSignedIn) { try await sharing(github(), token: nil).share(submission()) }
        let tokens = MemoryTokenStore("old")
        let revoked = StubNetwork { _ in StubReply(401, ["message": "Bad credentials"]) }
        await #expect(throws: SharingError.unauthorized) { try await sharing(revoked, store: tokens).share(submission()) }
        #expect(tokens.read() == nil)   // a token GitHub rejects is forgotten
    }

    @Test func gitHubErrorsCarryTheirMessage() async throws {
        let net = github(pulls: { _ in StubReply(403, ["message": "Resource not accessible"]) })
        await #expect(throws: SharingError.github(status: 403, message: "Resource not accessible")) { try await sharing(net).share(submission()) }
    }

    // MARK: Validation (mirrors scripts/build.py --check)

    private func edit(_ change: (inout [String: Any]) -> Void) throws -> Data {
        var o = try #require(try JSONSerialization.jsonObject(with: definition) as? [String: Any])
        change(&o)
        return try JSONSerialization.data(withJSONObject: o)
    }

    private func problems(_ data: Data, name: String = "Board", maker: String = "Maker") -> [String] {
        do { _ = try GitHubSharing.prepare(definition: data, name: name, maker: maker); return [] }
        catch SharingError.invalid(let p) { return p } catch { return ["\(error)"] }
    }

    @Test func aGoodDefinitionPassesAndOnlyRenamingChangesTheFile() throws {
        let same = try submission()
        #expect(same.json == definition && same.vidPid == "4335:0002" && same.keyCount == 61 && same.rows == 5 && same.cols == 14)
        #expect(same.path == "keyboards/geekhack/gh60-satan.json")
        let renamed = try submission(name: "  My Board ", maker: "Géekhack Labs")
        let name = (try JSONSerialization.jsonObject(with: renamed.json) as? [String: Any])?["name"] as? String
        #expect(name == "My Board" && renamed.path == "keyboards/geekhack-labs/my-board.json")
    }

    @Test func validationFailuresAreCaughtBeforeAnythingIsSent() throws {
        #expect(problems(definition, name: "  ").contains("Enter a name for the keyboard."))
        #expect(problems(definition, maker: "").contains("Enter the maker's name, like Keychron."))
        #expect(problems(Data("nope".utf8)).contains("The layout file isn't valid JSON."))
        #expect(!problems(try edit { $0["vendorId"] = "4335" }).isEmpty)   // CI wants "0x4335"
        #expect(!problems(try edit { $0["productId"] = nil }).isEmpty)
        #expect(!problems(try edit { $0["matrix"] = ["rows": 2, "cols": 2] }).isEmpty)   // keys fall outside the matrix
        #expect(!problems(try edit { $0["matrix"] = nil }).isEmpty)
        #expect(!problems(try edit { $0["layouts"] = ["keymap": [["a", "b"]]] }).isEmpty)   // no row,col keys
        #expect(!problems(try edit { $0["layouts"] = ["keymap": []] }).isEmpty)
        let huge = try edit { $0["padding"] = String(repeating: "x", count: GitHubSharing.maxBytes) }
        #expect(problems(huge).contains("The layout file is larger than 1 MB."))
    }

    @Test func keychainTokenStoreRoundTrips() {
        let store = KeychainTokenStore(service: "app.keycraft.github.tests.\(UUID().uuidString)")
        defer { store.delete() }
        #expect(store.read() == nil)
        try? store.save("one"); try? store.save("two")
        #expect(store.read() == "two")
        store.delete()
        #expect(store.read() == nil)
    }
}
