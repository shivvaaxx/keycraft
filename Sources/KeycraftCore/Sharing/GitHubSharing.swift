import Foundation
import Security

public enum SharingError: LocalizedError, Equatable {
    case notSignedIn, signInExpired, signInDenied, signInFailed(String), unauthorized
    case invalid([String])
    case github(status: Int, message: String)
    case forkNotReady
    case service(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in with GitHub first."
        case .signInExpired: "The code expired before it was approved. Start again to get a new one."
        case .signInDenied: "Access was declined on GitHub. Start again if that was a mistake."
        case .signInFailed(let why): "GitHub couldn't sign you in: \(why)"
        case .unauthorized: "GitHub no longer accepts this sign-in. Sign in again."
        case .invalid(let problems): problems.joined(separator: "\n")
        case .github(let status, let message): "GitHub answered with an error (\(status)): \(message)"
        case .forkNotReady: "Your copy of the library on GitHub isn't ready yet. Try again in a minute."
        case .service(_, let message): message
        }
    }
}

/// Where the GitHub token is kept. The real one is the Keychain; tests use memory.
public protocol GitHubTokenStore: Sendable {
    func read() -> String?
    func save(_ token: String) throws
    func delete()
}

public struct KeychainTokenStore: GitHubTokenStore {
    private let service: String
    private let account = "github-token"
    public init(service: String = "app.keycraft.github") { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func read() -> String? {
        var result: AnyObject?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 } as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ token: String) throws {
        delete()
        let status = SecItemAdd(query.merging([kSecValueData as String: Data(token.utf8)]) { $1 } as CFDictionary, nil)
        guard status == errSecSuccess else { throw SharingError.signInFailed("The token couldn't be saved to the Keychain (\(status)).") }
    }

    public func delete() { SecItemDelete(query as CFDictionary) }
}

/// What the user must do to approve a device-flow sign-in.
public struct DeviceCode: Sendable, Equatable {
    public let userCode: String
    public let verificationURL: URL
    let deviceCode: String
    let expiresIn: Int
    let interval: Int
}

/// What will be sent: one definition file and the pull request around it.
public struct Submission: Sendable, Equatable {
    public let name: String
    public let maker: String
    public let vendorID: Int
    public let productID: Int
    public let rows: Int
    public let cols: Int
    /// Keys drawn with the default layout options.
    public let keyCount: Int
    /// The only thing that leaves this Mac: the definition JSON.
    public let json: Data
    public var vidPid: String { String(format: "%04X:%04X", vendorID, productID) }
    public var path: String { "keyboards/\(GitHubSharing.slug(maker, fallback: "other"))/\(GitHubSharing.slug(name, fallback: "keyboard")).json" }
    public var branch: String {
        "add-\(GitHubSharing.slug(maker, fallback: "other"))-\(GitHubSharing.slug(name, fallback: "keyboard"))-" + String(format: "%04x%04x", vendorID, productID)
    }
}

/// Shares a keyboard definition with the public keyboard library: sign in with GitHub (OAuth device flow), push the file
/// to the user's fork, open a pull request. REST v3 over URLSession; the token lives only in the token store.
public struct GitHubSharing: Sendable {
    public static let maxBytes = 1024 * 1024
    private static let web = URL(string: "https://github.com")!

    private let clientID: String
    private let owner: String
    private let repo: String
    private let session: URLSession
    private let tokens: any GitHubTokenStore
    private let appVersion: String
    private let sleep: @Sendable (Duration) async throws -> Void

    /// Nil when the build has no GitHub configuration.
    public init?(clientID: String? = KeycraftConfig.githubClientID, repo: (owner: String, name: String)? = KeycraftConfig.databaseRepo,
                 session: URLSession = .shared, tokens: any GitHubTokenStore = KeychainTokenStore(), appVersion: String = "dev",
                 sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        guard let clientID, let repo else { return nil }
        (self.clientID, owner, self.repo, self.session, self.tokens, self.appVersion, self.sleep) =
            (clientID, repo.owner, repo.name, session, tokens, appVersion, sleep)
    }

    public var isSignedIn: Bool { tokens.read() != nil }
    public func signOut() { tokens.delete() }

    // MARK: Validation (mirrors scripts/build.py --check in keycraft-keyboards, so the pull request passes CI)

    /// Lowercase `a-z0-9` words joined by hyphens, like the library's own file names.
    static func slug(_ text: String, fallback: String) -> String {
        let folded = text.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        let words = folded.split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
        return words.isEmpty ? fallback : words.joined(separator: "-")
    }

    /// Checks the definition and the chosen name and maker; throws `.invalid` listing everything wrong, in plain words.
    public static func prepare(definition data: Data, name: String, maker: String) throws -> Submission {
        var problems: [String] = []
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let maker = maker.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { problems.append("Enter a name for the keyboard.") }
        if maker.isEmpty { problems.append("Enter the maker's name, like Keychron.") }
        if data.count >= maxBytes { problems.append("The layout file is larger than 1 MB.") }
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SharingError.invalid(problems + ["The layout file isn't valid JSON."])
        }
        func hex(_ key: String) -> Int? {
            if let n = object[key] as? Int { return n }
            guard let s = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  s.wholeMatch(of: /0x[0-9a-fA-F]{1,4}/) != nil else { return nil }
            return Int(s.dropFirst(2), radix: 16)
        }
        let vid = hex("vendorId"), pid = hex("productId")
        if vid == nil { problems.append("The layout file needs a vendorId written like \"0x1234\".") }
        if pid == nil { problems.append("The layout file needs a productId written like \"0x1234\".") }
        let matrix = object["matrix"] as? [String: Any]
        let rows = matrix?["rows"] as? Int ?? 0, cols = matrix?["cols"] as? Int ?? 0
        if rows <= 0 || cols <= 0 { problems.append("The layout file needs a key matrix with rows and cols.") }
        var keyCount = 0
        if let keymap = (object["layouts"] as? [String: Any])?["keymap"] as? [Any], !keymap.isEmpty, keymap.allSatisfy({ $0 is [Any] }) {
            for case let row as [Any] in keymap {
                for case let item as String in row {
                    let position = item.components(separatedBy: "\n")[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let m = position.wholeMatch(of: /(\d+)\s*,\s*(\d+)/), let r = Int(m.1), let c = Int(m.2) else { continue }
                    keyCount += 1
                    if rows > 0, cols > 0, r >= rows || c >= cols { problems.append("Key \(position) is outside the \(rows) × \(cols) key matrix.") }
                }
            }
            if keyCount == 0 { problems.append("The layout has no keys with a row,column position.") }
        } else {
            problems.append("The layout file needs a keymap made of rows of keys.")
        }
        let parsed = try? VIADefinition(data: data)
        if parsed == nil { problems.append("Keycraft can't read this layout file.") }
        guard problems.isEmpty, let vid, let pid else { throw SharingError.invalid(Array(Set(problems)).sorted()) }

        var json = data
        if object["name"] as? String != name {   // only touch the file if the user renamed the keyboard
            object["name"] = name
            json = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? data
        }
        return Submission(name: name, maker: maker, vendorID: vid, productID: pid, rows: rows, cols: cols, keyCount: parsed?.keys.count ?? keyCount, json: json)
    }

    // MARK: Sign in (device flow)

    public func requestDeviceCode() async throws -> DeviceCode {
        let (_, body) = try await send("POST", Self.web.appending(path: "login/device/code"), form: ["client_id": clientID, "scope": "public_repo"])
        guard let o = object(body), let device = o["device_code"] as? String, let user = o["user_code"] as? String,
              let uri = (o["verification_uri"] as? String).flatMap(URL.init(string:)), uri.scheme == "https" else {
            throw SharingError.signInFailed((object(body)?["error_description"] as? String) ?? "GitHub sent an unexpected answer.")
        }
        return DeviceCode(userCode: user, verificationURL: uri, deviceCode: device,
                          expiresIn: o["expires_in"] as? Int ?? 900, interval: o["interval"] as? Int ?? 5)
    }

    /// Polls until the user approves; stores the token. Honors `interval` and `slow_down`; cancel the task to stop.
    public func completeSignIn(_ code: DeviceCode) async throws {
        var interval = max(code.interval, 1), waited = 0
        while true {
            try await sleep(.seconds(interval))
            waited += interval
            let (_, body) = try await send("POST", Self.web.appending(path: "login/oauth/access_token"), form: [
                "client_id": clientID, "device_code": code.deviceCode, "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
            let o = object(body)
            if let token = o?["access_token"] as? String { try tokens.save(token); return }
            switch o?["error"] as? String {
            case "authorization_pending": break
            case "slow_down": interval = max(interval + 5, o?["interval"] as? Int ?? 0)
            case "expired_token": throw SharingError.signInExpired
            case "access_denied": throw SharingError.signInDenied
            default: throw SharingError.signInFailed((o?["error_description"] as? String) ?? (o?["error"] as? String) ?? "unknown error")
            }
            if waited >= code.expiresIn { throw SharingError.signInExpired }
        }
    }

    /// The signed-in account's login name.
    public func login() async throws -> String {
        let (_, body) = try await api("GET", "user")
        guard let login = object(body)?["login"] as? String else { throw SharingError.github(status: 200, message: "No account name in the answer.") }
        return login
    }

    // MARK: Share

    /// Pushes the submission to the user's fork and opens a pull request. Returns the pull request URL (the existing
    /// one if this keyboard was already submitted).
    public func share(_ submission: Submission, progress: @Sendable (String) -> Void = { _ in }) async throws -> URL {
        let me = try await login()
        // The owner can't fork their own repo; they push a branch straight to it.
        var (forkOwner, forkRepo) = (owner, repo)
        if me.lowercased() != owner.lowercased() {
            progress("Copying the library to your GitHub account…")
            let (_, forked) = try await api("POST", "repos/\(owner)/\(repo)/forks")
            let fork = object(forked)
            forkOwner = (fork?["owner"] as? [String: Any])?["login"] as? String ?? me
            forkRepo = fork?["name"] as? String ?? repo
            try await waitForFork(forkOwner, forkRepo)
        }
        progress("Creating pull request…")
        let (_, upstream) = try await api("GET", "repos/\(owner)/\(repo)")
        let base = object(upstream)?["default_branch"] as? String ?? "main"
        let (_, ref) = try await api("GET", "repos/\(owner)/\(repo)/git/ref/heads/\(base)")
        guard let sha = (object(ref)?["object"] as? [String: Any])?["sha"] as? String else {
            throw SharingError.github(status: 200, message: "The library's main branch has no commit.")
        }

        let (refStatus, refBody) = try await api("POST", "repos/\(forkOwner)/\(forkRepo)/git/refs",
                                                json: ["ref": "refs/heads/\(submission.branch)", "sha": sha], allowing: [422])
        var existingFileSHA: String?
        if refStatus == 422 {   // branch left over from an earlier try: update the file on it
            guard message(refBody).localizedCaseInsensitiveContains("exist") else { throw SharingError.github(status: 422, message: message(refBody)) }
            let (status, file) = try await api("GET", "repos/\(forkOwner)/\(forkRepo)/contents/\(submission.path)?ref=\(submission.branch)", allowing: [404])
            if status == 200 { existingFileSHA = object(file)?["sha"] as? String }
        }

        var put: [String: Any] = ["message": "Add \(submission.name) (\(submission.vidPid))", "content": submission.json.base64EncodedString(), "branch": submission.branch]
        put["sha"] = existingFileSHA
        _ = try await api("PUT", "repos/\(forkOwner)/\(forkRepo)/contents/\(submission.path)", json: put)

        let head = "\(forkOwner):\(submission.branch)"
        let body = """
            **\(submission.name)**

            - Vendor and product ID: \(submission.vidPid)
            - Matrix: \(submission.rows) rows × \(submission.cols) columns, \(submission.keyCount) keys

            Submitted from Keycraft \(appVersion)
            """
        let (prStatus, pr) = try await api("POST", "repos/\(owner)/\(repo)/pulls",
                                           json: ["title": "Add \(submission.name) (\(submission.vidPid))", "head": head, "base": base, "body": body], allowing: [422])
        if prStatus == 201, let url = (object(pr)?["html_url"] as? String).flatMap(URL.init(string:)) { return url }
        // 422: a pull request for this branch already exists.
        let query = "head=\(head)&state=open".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let (_, list) = try await api("GET", "repos/\(owner)/\(repo)/pulls?\(query)")
        guard let first = (try? JSONSerialization.jsonObject(with: list)) as? [[String: Any]],
              let url = (first.first?["html_url"] as? String).flatMap(URL.init(string:)) else {
            throw SharingError.github(status: prStatus, message: message(pr))
        }
        return url
    }

    private func waitForFork(_ forkOwner: String, _ forkRepo: String) async throws {
        for attempt in 0..<30 {
            let (status, _) = try await api("GET", "repos/\(forkOwner)/\(forkRepo)", allowing: [404])
            if status == 200 { return }
            if attempt < 29 { try await sleep(.seconds(2)) }
        }
        throw SharingError.forkNotReady
    }

    // MARK: HTTP

    private func object(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
    private func message(_ data: Data) -> String { (object(data)?["message"] as? String) ?? "no details" }

    /// An authenticated GitHub API call. Statuses in `allowing` are returned instead of thrown.
    private func api(_ method: String, _ path: String, json: [String: Any]? = nil, allowing: Set<Int> = []) async throws -> (Int, Data) {
        guard let token = tokens.read() else { throw SharingError.notSignedIn }
        guard let url = URL(string: "https://api.github.com/" + path) else { throw SharingError.github(status: 0, message: "Bad address.") }
        let (status, data) = try await send(method, url, json: json, token: token)
        if status == 401 { tokens.delete(); throw SharingError.unauthorized }
        guard (200..<300).contains(status) || allowing.contains(status) else { throw SharingError.github(status: status, message: message(data)) }
        return (status, data)
    }

    private func send(_ method: String, _ url: URL, json: [String: Any]? = nil, form: [String: String]? = nil, token: String? = nil) async throws -> (Int, Data) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Keycraft/\(appVersion)", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let form {
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&=+:")
            request.httpBody = Data(form.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
