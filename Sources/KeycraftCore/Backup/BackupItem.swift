import Foundation

public struct BackupItem: Sendable, Identifiable {
    public enum Importance: String, Codable, Sendable { case important, optional }

    public let id: String
    public let name: String
    public let importance: Importance
    /// Shown when `read` returns nil. (Added to the spec'd shape: nil alone can't carry a reason.)
    public let notSupportedReason: String
    /// nil = this protocol can't read the item at all.
    public let read: @Sendable () async throws -> Data?

    public init(id: String, name: String, importance: Importance,
                notSupportedReason: String = "Not supported by this protocol",
                read: @escaping @Sendable () async throws -> Data?) {
        self.id = id
        self.name = name
        self.importance = importance
        self.notSupportedReason = notSupportedReason
        self.read = read
    }
}

public enum BackupResult: Sendable {
    case saved(Data)
    case failed(String)
    case notSupported(String)
}

/// One item's outcome as written to the backup file.
public struct BackupEntry: Codable, Sendable, Identifiable, Equatable {
    public enum Status: String, Codable, Sendable { case saved, failed, notSupported }

    public let id: String
    public let name: String
    public let importance: BackupItem.Importance
    public let status: Status
    public let reason: String?
    public let dataBase64: String?

    public var data: Data? { dataBase64.flatMap { Data(base64Encoded: $0) } }

    init(item: BackupItem, result: BackupResult) {
        id = item.id
        name = item.name
        importance = item.importance
        switch result {
        case .saved(let d): (status, reason, dataBase64) = (.saved, nil, d.base64EncodedString())
        case .failed(let why): (status, reason, dataBase64) = (.failed, why, nil)
        case .notSupported(let why): (status, reason, dataBase64) = (.notSupported, why, nil)
        }
    }
}
