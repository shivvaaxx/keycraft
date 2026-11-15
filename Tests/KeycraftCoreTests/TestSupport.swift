import Foundation
import os
import Testing
@testable import KeycraftCore

/// Wraps the mock to inject behaviour the mock itself doesn't have.
final class SpyTransport: HIDTransport {
    let base: MockVIADevice
    var info: HIDDeviceInfo { base.info }
    private let reportedVersion: Int?
    private let dropWrites: Bool
    private let delay: Duration?
    private struct Gauge { var inFlight = 0; var maxInFlight = 0 }
    private let gauge = OSAllocatedUnfairLock(initialState: Gauge())

    init(_ base: MockVIADevice, reportedVersion: Int? = nil, dropWrites: Bool = false, delay: Duration? = nil) {
        self.base = base
        self.reportedVersion = reportedVersion
        self.dropWrites = dropWrites
        self.delay = delay
    }

    var maxInFlight: Int { gauge.withLock { $0.maxInFlight } }

    func send(_ report: [UInt8], timeout: Duration) async throws -> [UInt8] {
        gauge.withLock { $0.inFlight += 1; $0.maxInFlight = max($0.maxInFlight, $0.inFlight) }
        defer { gauge.withLock { $0.inFlight -= 1 } }
        if let delay { try await Task.sleep(for: delay) }
        if dropWrites && report[0] == VIACommand.setKeycode.rawValue { return report } // echo without applying
        var r = try await base.send(report, timeout: timeout)
        if let v = reportedVersion, report[0] == VIACommand.getProtocolVersion.rawValue {
            r[1] = UInt8(v >> 8); r[2] = UInt8(v & 0xFF)
        }
        return r
    }

    func close() {}
}

func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "keycraft-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func fixture(_ name: String) throws -> Data {
    let folder = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    return try Data(contentsOf: folder.appending(path: name))
}

// MARK: Network stubs (no real network in tests)

struct StubRequest: Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data
    var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
    /// e.g. "POST api.github.com/repos/a/b/forks"
    var label: String { "\(method) \(url.host() ?? "")\(url.path())" }
}

struct StubReply: Sendable {
    let status: Int
    let body: Data
    init(_ status: Int, _ json: Any = [String: String]()) {
        self.status = status
        body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }
    init(_ status: Int, data: Data) { self.status = status; body = data }
}

/// A URLSession whose every request is answered by `handler`; requests are recorded. Safe for parallel tests.
final class StubNetwork: Sendable {
    fileprivate static let registry = OSAllocatedUnfairLock<[String: StubNetwork]>(initialState: [:])
    let id = UUID().uuidString
    let session: URLSession
    let handler: @Sendable (StubRequest) -> StubReply
    private let recorded = OSAllocatedUnfairLock<[StubRequest]>(initialState: [])
    var requests: [StubRequest] { recorded.withLock { $0 } }
    var labels: [String] { requests.map(\.label) }

    init(_ handler: @escaping @Sendable (StubRequest) -> StubReply) {
        self.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Stub-ID": id]
        session = URLSession(configuration: configuration)
        Self.registry.withLock { $0[id] = self }
    }

    fileprivate func answer(_ request: StubRequest) -> StubReply {
        recorded.withLock { $0.append(request) }
        return handler(request)
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        let headers = request.allHTTPHeaderFields ?? [:]
        guard let url = request.url, let id = headers["X-Stub-ID"], let network = StubNetwork.registry.withLock({ $0[id] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let reply = network.answer(StubRequest(method: request.httpMethod ?? "GET", url: url, headers: headers, body: body))
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class MemoryTokenStore: GitHubTokenStore {
    private let value: OSAllocatedUnfairLock<String?>
    init(_ token: String? = nil) { value = OSAllocatedUnfairLock(initialState: token) }
    func read() -> String? { value.withLock { $0 } }
    func save(_ token: String) throws { value.withLock { $0 = token } }
    func delete() { value.withLock { $0 = nil } }
}
