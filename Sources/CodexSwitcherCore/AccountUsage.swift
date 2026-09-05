import Foundation

public struct AccountUsage: Codable, Identifiable, Equatable, Sendable {
    public let name: String
    public let fiveHourRemaining: Int
    public let fiveHourReset: String
    public let weeklyRemaining: Int
    public let weeklyReset: String
    public let resetCards: Int
    public let notedAt: String

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case fiveHourRemaining = "five_hour_remaining"
        case fiveHourReset = "five_hour_reset"
        case weeklyRemaining = "weekly_remaining"
        case weeklyReset = "weekly_reset"
        case resetCards = "reset_cards"
        case notedAt = "noted_at"
    }

    public init(
        name: String,
        fiveHourRemaining: Int,
        fiveHourReset: String,
        weeklyRemaining: Int,
        weeklyReset: String,
        resetCards: Int,
        notedAt: String
    ) {
        self.name = name
        self.fiveHourRemaining = fiveHourRemaining
        self.fiveHourReset = fiveHourReset
        self.weeklyRemaining = weeklyRemaining
        self.weeklyReset = weeklyReset
        self.resetCards = resetCards
        self.notedAt = notedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = decoder.userInfo[.accountName] as? String ?? ""
        fiveHourRemaining = try container.decode(Int.self, forKey: .fiveHourRemaining)
        fiveHourReset = try container.decode(String.self, forKey: .fiveHourReset)
        weeklyRemaining = try container.decode(Int.self, forKey: .weeklyRemaining)
        weeklyReset = try container.decode(String.self, forKey: .weeklyReset)
        resetCards = try container.decodeIfPresent(Int.self, forKey: .resetCards) ?? 0
        notedAt = try container.decode(String.self, forKey: .notedAt)
    }
}

public extension CodingUserInfoKey {
    static let accountName = CodingUserInfoKey(rawValue: "accountName")!
}

public enum UsageStore {
    public static func decode(_ data: Data) throws -> [AccountUsage] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let records = object as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try records.map { name, value in
            let data = try JSONSerialization.data(withJSONObject: value)
            let decoder = JSONDecoder()
            decoder.userInfo[.accountName] = name
            return try decoder.decode(AccountUsage.self, from: data)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

public enum AccountRecommender {
    public static func next(
        from accounts: [AccountUsage],
        currentAccount: String?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> AccountUsage? {
        ranked(from: accounts, currentAccount: currentAccount, now: now, calendar: calendar)
            .first { isSwitchCandidate($0, currentAccount: currentAccount, now: now, calendar: calendar) }
    }

    public static func ranked(
        from accounts: [AccountUsage],
        currentAccount: String?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [AccountUsage] {
        accounts.sorted { left, right in
            let leftGroup = rankGroup(left, currentAccount: currentAccount, now: now, calendar: calendar)
            let rightGroup = rankGroup(right, currentAccount: currentAccount, now: now, calendar: calendar)
            if leftGroup != rightGroup { return leftGroup < rightGroup }

            if leftGroup == 0 {
                let leftReset = resetDate(left.fiveHourReset, calendar: calendar) ?? .distantFuture
                let rightReset = resetDate(right.fiveHourReset, calendar: calendar) ?? .distantFuture
                if leftReset != rightReset { return leftReset < rightReset }
            } else if leftGroup == 2 {
                if left.weeklyRemaining != right.weeklyRemaining {
                    return left.weeklyRemaining > right.weeklyRemaining
                }
                if left.fiveHourRemaining != right.fiveHourRemaining {
                    return left.fiveHourRemaining > right.fiveHourRemaining
                }
            }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    private static func rankGroup(
        _ account: AccountUsage,
        currentAccount: String?,
        now: Date,
        calendar: Calendar
    ) -> Int {
        if isSwitchCandidate(account, currentAccount: currentAccount, now: now, calendar: calendar) { return 0 }
        if account.name == currentAccount { return 1 }
        return 2
    }

    private static func isSwitchCandidate(
        _ account: AccountUsage,
        currentAccount: String?,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        account.name != currentAccount
            && account.weeklyRemaining > 0
            && account.fiveHourRemaining > 0
            && resetDate(account.fiveHourReset, calendar: calendar).map { $0 >= now } == true
    }

    public static func resetDate(_ value: String, calendar: Calendar = .current) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: value)
    }
}
