import Foundation
import XCTest
@testable import CodexSwitcherCore

final class CodexSwitcherCoreTests: XCTestCase {
    func testSelectsAvailableAccountLoginMethod() {
        XCTAssertEqual(ClientAvailability(hasChatGPT: true, hasCodexCLI: true).accountLoginMethod, .chatGPT)
        XCTAssertEqual(ClientAvailability(hasChatGPT: true, hasCodexCLI: false).accountLoginMethod, .chatGPT)
        XCTAssertEqual(ClientAvailability(hasChatGPT: false, hasCodexCLI: true).accountLoginMethod, .codexCLI)
        XCTAssertEqual(ClientAvailability(hasChatGPT: false, hasCodexCLI: false).accountLoginMethod, .unavailable)
        XCTAssertFalse(ClientAvailability(hasChatGPT: false, hasCodexCLI: false).canAddAccount)
    }

    func testDecodesAndRecommendsNearestEligibleAccount() throws {
        let data = """
    {
      "current": {"five_hour_remaining": 90, "five_hour_reset": "2030-01-01 09:00", "weekly_remaining": 90, "weekly_reset": "1.2", "reset_cards": 0, "noted_at": "2026-09-05T10:00:00+08:00"},
      "nearest": {"five_hour_remaining": 40, "five_hour_reset": "2030-01-01 10:00", "weekly_remaining": 60, "weekly_reset": "1.2", "reset_cards": 1, "noted_at": "2026-09-05T10:00:00+08:00"},
      "later": {"five_hour_remaining": 50, "five_hour_reset": "2030-01-01 11:00", "weekly_remaining": 70, "weekly_reset": "1.2", "noted_at": "2026-09-05T10:00:00+08:00"},
      "weeklyZero": {"five_hour_remaining": 80, "five_hour_reset": "2030-01-01 09:30", "weekly_remaining": 0, "weekly_reset": "1.2", "noted_at": "2026-09-05T10:00:00+08:00"}
    }
    """.data(using: .utf8)!
        let accounts = try UsageStore.decode(data)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(AccountRecommender.resetDate("2030-01-01 08:00", calendar: calendar))
        let result = AccountRecommender.next(from: accounts, currentAccount: "current", now: now, calendar: calendar)
        XCTAssertEqual(result?.name, "nearest")
        XCTAssertEqual(result?.resetCards, 1)
    }
}
