import Foundation

public enum TokenUsagePeriod: CaseIterable, Sendable { case fiveHours, today, currentWeek }

public struct TokenUsageTotals: Equatable, Sendable {
    public var input = 0
    public var cachedInput = 0
    public var cacheWriteInput = 0
    public var output = 0
    public var reasoningOutput = 0
    public var estimatedUSD = 0.0
    public var unpricedEvents = 0

    public var total: Int { input + output }
}

public struct TokenUsageEvent: Codable, Equatable, Sendable {
    public let id: String
    public let account: String
    public let timestamp: Date
    public let model: String
    public let input: Int
    public let cachedInput: Int
    public let cacheWriteInput: Int
    public let output: Int
    public let reasoningOutput: Int

    public init(id: String, account: String, timestamp: Date, model: String, input: Int, cachedInput: Int, cacheWriteInput: Int, output: Int, reasoningOutput: Int) {
        self.id = id
        self.account = account
        self.timestamp = timestamp
        self.model = model
        self.input = input
        self.cachedInput = cachedInput
        self.cacheWriteInput = cacheWriteInput
        self.output = output
        self.reasoningOutput = reasoningOutput
    }
}

public enum ModelPricing {
    private struct Rate { let input: Double; let cached: Double; let output: Double }
    private static let rates: [String: Rate] = [
        "gpt-6-astra": .init(input: 10, cached: 1, output: 50),
        "gpt-5.6-sol": .init(input: 4, cached: 0.4, output: 20),
        "gpt-5.6": .init(input: 4, cached: 0.4, output: 20),
        "gpt-5.6-terra": .init(input: 2, cached: 0.2, output: 12),
        "gpt-5.6-luna": .init(input: 0.2, cached: 0.02, output: 1.2),
    ]

    public static func estimatedUSD(for event: TokenUsageEvent) -> Double? {
        guard let rate = rates[event.model] else { return nil }
        let uncached = max(0, event.input - event.cachedInput - event.cacheWriteInput)
        let amount = Double(uncached) * rate.input
            + Double(event.cachedInput) * rate.cached
            + Double(event.cacheWriteInput) * rate.input * 1.25
            + Double(event.output) * rate.output
        return amount / 1_000_000
    }
}

public final class TokenUsageTracker: @unchecked Sendable {
    private struct State: Codable {
        var activeAccount: String
        var cursors: [String: UInt64]
        var models: [String: String]
        var events: [TokenUsageEvent]
    }

    private let roots: [URL]
    private let stateURL: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(roots: [URL], stateURL: URL) {
        self.roots = roots
        self.stateURL = stateURL
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func scan(account: String) throws -> [TokenUsageEvent] {
        let files = sessionFiles()
        guard var state = try loadState() else {
            try save(State(activeAccount: account, cursors: endOffsets(files), models: [:], events: []))
            return []
        }
        guard state.activeAccount == account else {
            state.activeAccount = account
            state.cursors = endOffsets(files)
            state.models = [:]
            try save(state)
            return state.events
        }

        for file in files {
            let key = file.lastPathComponent
            let start = state.cursors[key] ?? 0
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            guard !data.isEmpty else { continue }
            guard let lastNewline = data.lastIndex(of: 0x0A) else { continue }
            let complete = data.prefix(through: lastNewline)
            var lineStart = complete.startIndex
            while lineStart < complete.endIndex {
                guard let newline = complete[lineStart...].firstIndex(of: 0x0A) else { break }
                let line = complete[lineStart..<newline]
                let offset = start + UInt64(lineStart)
                process(line: Data(line), fileKey: key, offset: offset, state: &state)
                lineStart = complete.index(after: newline)
            }
            state.cursors[key] = start + UInt64(complete.count)
        }
        try save(state)
        return state.events
    }

    public func totals(events: [TokenUsageEvent], account: String, from start: Date, to end: Date = Date()) -> TokenUsageTotals {
        events.lazy.filter { $0.account == account && $0.timestamp >= start && $0.timestamp <= end }
            .reduce(into: TokenUsageTotals()) { totals, event in
                totals.input += event.input
                totals.cachedInput += event.cachedInput
                totals.cacheWriteInput += event.cacheWriteInput
                totals.output += event.output
                totals.reasoningOutput += event.reasoningOutput
                if let price = ModelPricing.estimatedUSD(for: event) {
                    totals.estimatedUSD += price
                } else {
                    totals.unpricedEvents += 1
                }
            }
    }

    private func process(line: Data, fileKey: String, offset: UInt64, state: inout State) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return }
        if object["type"] as? String == "turn_context", let model = payload["model"] as? String {
            state.models[fileKey] = model
            return
        }
        guard object["type"] as? String == "event_msg",
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let usage = info["last_token_usage"] as? [String: Any],
              let timestampText = object["timestamp"] as? String,
              let timestamp = parseTimestamp(timestampText) else { return }
        func number(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        state.events.append(TokenUsageEvent(
            id: "\(fileKey):\(offset)", account: state.activeAccount, timestamp: timestamp,
            model: state.models[fileKey] ?? "unknown", input: number("input_tokens"),
            cachedInput: number("cached_input_tokens"), cacheWriteInput: number("cache_write_input_tokens"),
            output: number("output_tokens"), reasoningOutput: number("reasoning_output_tokens")
        ))
    }

    private func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func sessionFiles() -> [URL] {
        roots.flatMap { root -> [URL] in
            guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
            return iterator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
        }
    }

    private func endOffsets(_ files: [URL]) -> [String: UInt64] {
        files.reduce(into: [:]) { result, file in
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return }
            result[file.lastPathComponent] = UInt64(size)
        }
    }

    private func loadState() throws -> State? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        return try decoder.decode(State.self, from: Data(contentsOf: stateURL))
    }

    private func save(_ state: State) throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }
}
