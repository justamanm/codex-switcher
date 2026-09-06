import Foundation

public struct WeeklyQuotaProjection: Codable, Equatable, Sendable {
    public let estimatedFullUSD: Double
    public let observedUsedPercent: Int
    public let observedUSD: Double
    public let isPartial: Bool
    public let updatedAt: Date
}

public final class WeeklyQuotaProjectionStore: @unchecked Sendable {
    private struct Sample: Codable {
        let remainingPercent: Int
        let estimatedUSD: Double
        let unpricedEvents: Int
    }

    private struct AccountState: Codable {
        var resetAt: String
        var sample: Sample?
        var observedUsedPercent: Int
        var observedUSD: Double
        var isPartial: Bool
        var projection: WeeklyQuotaProjection?
    }

    private let url: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(url: URL) {
        self.url = url
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func begin(
        account: String,
        resetAt: String,
        remainingPercent: Int,
        estimatedUSD: Double,
        unpricedEvents: Int
    ) throws {
        var states = loadStates()
        var state = states[account]
        if state?.resetAt != resetAt {
            state = AccountState(
                resetAt: resetAt,
                sample: nil,
                observedUsedPercent: 0,
                observedUSD: 0,
                isPartial: false,
                projection: nil
            )
        }
        state?.sample = Sample(
            remainingPercent: remainingPercent,
            estimatedUSD: estimatedUSD,
            unpricedEvents: unpricedEvents
        )
        states[account] = state
        try save(states)
    }

    public func beginIfNeeded(
        account: String,
        resetAt: String,
        remainingPercent: Int,
        estimatedUSD: Double,
        unpricedEvents: Int
    ) throws {
        let state = loadStates()[account]
        guard state?.resetAt != resetAt || state?.sample == nil else { return }
        try begin(
            account: account,
            resetAt: resetAt,
            remainingPercent: remainingPercent,
            estimatedUSD: estimatedUSD,
            unpricedEvents: unpricedEvents
        )
    }

    @discardableResult
    public func finish(
        account: String,
        resetAt: String,
        remainingPercent: Int,
        estimatedUSD: Double,
        unpricedEvents: Int,
        at date: Date = Date()
    ) throws -> WeeklyQuotaProjection? {
        var states = loadStates()
        guard var state = states[account], state.resetAt == resetAt, let sample = state.sample else {
            return nil
        }
        state.sample = nil
        let usedPercent = sample.remainingPercent - remainingPercent
        let usedUSD = estimatedUSD - sample.estimatedUSD
        if usedPercent > 0, usedUSD > 0 {
            state.observedUsedPercent += usedPercent
            state.observedUSD += usedUSD
            state.isPartial = state.isPartial || unpricedEvents > sample.unpricedEvents
            state.projection = WeeklyQuotaProjection(
                estimatedFullUSD: state.observedUSD / Double(state.observedUsedPercent) * 100,
                observedUsedPercent: state.observedUsedPercent,
                observedUSD: state.observedUSD,
                isPartial: state.isPartial,
                updatedAt: date
            )
        }
        states[account] = state
        try save(states)
        return state.projection
    }

    @discardableResult
    public func observe(
        account: String,
        resetAt: String,
        remainingPercent: Int,
        estimatedUSD: Double,
        unpricedEvents: Int,
        at date: Date = Date()
    ) throws -> WeeklyQuotaProjection? {
        var states = loadStates()
        guard var state = states[account], state.resetAt == resetAt, let sample = state.sample else {
            return nil
        }
        let usedPercent = sample.remainingPercent - remainingPercent
        let usedUSD = estimatedUSD - sample.estimatedUSD
        if usedPercent > 0, usedUSD > 0 {
            state.observedUsedPercent += usedPercent
            state.observedUSD += usedUSD
            state.isPartial = state.isPartial || unpricedEvents > sample.unpricedEvents
            state.projection = WeeklyQuotaProjection(
                estimatedFullUSD: state.observedUSD / Double(state.observedUsedPercent) * 100,
                observedUsedPercent: state.observedUsedPercent,
                observedUSD: state.observedUSD,
                isPartial: state.isPartial,
                updatedAt: date
            )
            state.sample = Sample(
                remainingPercent: remainingPercent,
                estimatedUSD: estimatedUSD,
                unpricedEvents: unpricedEvents
            )
        } else if usedPercent < 0 || usedUSD < 0 {
            state.sample = Sample(
                remainingPercent: remainingPercent,
                estimatedUSD: estimatedUSD,
                unpricedEvents: unpricedEvents
            )
        }
        states[account] = state
        try save(states)
        return state.projection
    }

    public func projections() -> [String: WeeklyQuotaProjection] {
        loadStates().compactMapValues(\.projection)
    }

    private func loadStates() -> [String: AccountState] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? decoder.decode([String: AccountState].self, from: data)) ?? [:]
    }

    private func save(_ states: [String: AccountState]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(states).write(to: url, options: .atomic)
    }
}
