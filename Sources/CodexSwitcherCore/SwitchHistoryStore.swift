import Foundation

public enum SwitchResult: String, Codable, Sendable { case success, failure }

public struct SwitchHistoryRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let fromAccount: String
    public let toAccount: String
    public let result: SwitchResult
    public let message: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), fromAccount: String, toAccount: String, result: SwitchResult, message: String = "") {
        self.id = id
        self.timestamp = timestamp
        self.fromAccount = fromAccount
        self.toAccount = toAccount
        self.result = result
        self.message = message
    }
}

public final class SwitchHistoryStore: @unchecked Sendable {
    private let url: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(url: URL) {
        self.url = url
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func load() -> [SwitchHistoryRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([SwitchHistoryRecord].self, from: data)) ?? []
    }

    @discardableResult
    public func append(_ record: SwitchHistoryRecord) throws -> [SwitchHistoryRecord] {
        var records = load()
        records.insert(record, at: 0)
        if records.count > 500 { records.removeLast(records.count - 500) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(records).write(to: url, options: .atomic)
        return records
    }
}
