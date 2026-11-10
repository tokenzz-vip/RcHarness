import Foundation
import XCTest
@testable import RcHarness

final class StatisticsRangeTests: XCTestCase {
    func testLastSevenDaysUsesOneWindowAcrossCalendarWeekBoundary() throws {
        let calendar = makeCalendar()
        let now = date(2026, 11, 9, hour: 12, calendar: calendar) // Monday
        let start = date(2026, 11, 3, calendar: calendar)
        let usage = LocalUsage(days: [
            UsageDay(date: date(2026, 11, 2, calendar: calendar), presses: ["buttonA": 100], voiceSeconds: 100),
            UsageDay(date: start, presses: ["buttonA": 2], voiceSeconds: 2),
            UsageDay(date: date(2026, 11, 8, calendar: calendar), presses: ["netflix": 3], voiceSeconds: 3),
            UsageDay(date: date(2026, 11, 9, calendar: calendar), presses: ["buttonY": 4], voiceSeconds: 4),
            UsageDay(date: date(2026, 11, 10, calendar: calendar), presses: ["buttonA": 200], voiceSeconds: 200)
        ], sessions: [
            VoiceUsageSession(date: start.addingTimeInterval(-1), seconds: 100),
            VoiceUsageSession(date: start, seconds: 2),
            VoiceUsageSession(date: now, seconds: 4),
            VoiceUsageSession(date: now.addingTimeInterval(1), seconds: 200)
        ])
        let summary = UsageSummary(usage: usage, range: .lastSevenDays, now: now, calendar: calendar)
        XCTAssertEqual(summary.startDate, start)
        XCTAssertEqual(summary.endDate, calendar.startOfDay(for: now))
        XCTAssertEqual(summary.chartBuckets.count, 7)
        XCTAssertEqual(summary.pressCount, 9)
        XCTAssertEqual(summary.voiceSeconds, 9)
        XCTAssertEqual(summary.activeDays, 3)
        XCTAssertEqual(summary.rankedSessions.map(\.seconds), [4, 2])
        assertTotalsAgree(summary)

        var sundayFirst = calendar
        sundayFirst.firstWeekday = 1
        let otherConvention = UsageSummary(usage: usage, range: .lastSevenDays, now: now, calendar: sundayFirst)
        XCTAssertEqual(otherConvention.startDate, start)
        XCTAssertEqual(otherConvention.pressCount, summary.pressCount)
        XCTAssertEqual(otherConvention.chartBuckets.map(\.date), summary.chartBuckets.map(\.date))
    }

    func testSevenCalendarDaysSurviveBothDaylightSavingTransitions() {
        let calendar = makeCalendar(timeZone: "America/New_York")
        for (month, day, hours) in [(3, 10, 23), (11, 3, 25)] {
            let now = date(2026, month, day, hour: 12, calendar: calendar)
            let summary = UsageSummary(usage: LocalUsage(), range: .lastSevenDays, now: now, calendar: calendar)
            let dates = summary.chartBuckets.map(\.date)
            XCTAssertEqual(dates.count, 7)
            XCTAssertEqual(dates.last, calendar.startOfDay(for: now))
            XCTAssertEqual(Set(dates).count, 7)
            let intervals = zip(dates, dates.dropFirst()).map { $1.timeIntervalSince($0) }
            XCTAssertTrue(intervals.contains(Double(hours * 3600)))
        }
    }

    func testAllHistoryUsesMonthlyBucketsWithoutDroppingOlderRecords() {
        let calendar = makeCalendar()
        let now = date(2026, 11, 9, hour: 12, calendar: calendar)
        let usage = LocalUsage(days: [
            UsageDay(date: date(2026, 8, 31, calendar: calendar), presses: ["buttonY": 5], voiceSeconds: 12),
            UsageDay(date: date(2026, 11, 9, calendar: calendar), presses: ["netflix": 7], voiceSeconds: 9)
        ])
        let summary = UsageSummary(usage: usage, range: .all, now: now, calendar: calendar)
        XCTAssertEqual(summary.chartResolution, .month)
        XCTAssertEqual(summary.chartBuckets.count, 4)
        XCTAssertEqual(summary.chartBuckets.map(\.count), [5, 0, 0, 7])
        XCTAssertEqual(summary.activeDays, 2)
        XCTAssertEqual(summary.pressCount, 12)
        assertTotalsAgree(summary)
    }

    func testAllHistoryUsesYearlyBucketsAcrossYearBoundaries() {
        let calendar = makeCalendar()
        let now = date(2026, 11, 9, hour: 12, calendar: calendar)
        let usage = LocalUsage(days: [
            UsageDay(date: date(2024, 12, 31, calendar: calendar), presses: ["buttonY": 2], voiceSeconds: 3),
            UsageDay(date: date(2025, 1, 1, calendar: calendar), presses: ["netflix": 4], voiceSeconds: 5),
            UsageDay(date: date(2026, 11, 9, calendar: calendar), presses: ["buttonA": 6], voiceSeconds: 7)
        ])
        let summary = UsageSummary(usage: usage, range: .all, now: now, calendar: calendar)
        XCTAssertEqual(summary.chartResolution, .year)
        XCTAssertEqual(summary.chartBuckets.count, 3)
        XCTAssertEqual(summary.chartBuckets.map(\.count), [2, 4, 6])
        XCTAssertEqual(summary.startDate, date(2024, 12, 31, calendar: calendar))
        assertTotalsAgree(summary)
    }

    func testAllInputKeysAndDuplicateDaysContributeToTheSameTotals() {
        let calendar = makeCalendar()
        let now = date(2026, 11, 9, hour: 12, calendar: calendar)
        let usage = LocalUsage(days: [
            UsageDay(date: calendar.startOfDay(for: now), presses: ["buttonY": 2, "buttonA": 1]),
            UsageDay(date: now, presses: ["netflix": 3, "buttonA": 4, "legacy-button": 5])
        ])
        for range in StatisticsRange.allCases {
            let summary = UsageSummary(usage: usage, range: range, now: now, calendar: calendar)
            XCTAssertEqual(summary.pressCount, 15)
            XCTAssertEqual(summary.activeDays, 1)
            XCTAssertEqual(summary.buttonRanking.first { $0.key == "buttonA" }?.value, 5)
            XCTAssertEqual(summary.buttonRanking.first { $0.key == "legacy-button" }?.value, 5)
            assertTotalsAgree(summary)
        }
    }

    @MainActor
    func testChangingSelectedRemoteDoesNotChangeTheGlobalRanking() throws {
        let suite = "RcHarness.StatisticsRangeTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let now = Date()
        model.usageStore.record(.buttonY, at: now)
        model.usageStore.record(.netflix, at: now)
        model.usageStore.recordVoice(seconds: 5, at: now)
        let before = UsageSummary(usage: model.usageStore.usage, range: .lastSevenDays, now: now)
        for profile in model.availableRemoteProfiles {
            model.selectRemoteProfile(profile.id)
            let after = UsageSummary(usage: model.usageStore.usage, range: .lastSevenDays, now: now)
            XCTAssertEqual(after.pressCount, 2)
            XCTAssertEqual(after.buttonRanking.map(\.key), before.buttonRanking.map(\.key))
            XCTAssertEqual(after.buttonRanking.map(\.value), before.buttonRanking.map(\.value))
            XCTAssertEqual(after.rankedSessions.map(\.id), before.rankedSessions.map(\.id))
            assertTotalsAgree(after)
        }
    }

    private func assertTotalsAgree(_ summary: UsageSummary, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(summary.chartBuckets.reduce(0) { $0 + $1.count }, summary.pressCount, file: file, line: line)
        XCTAssertEqual(summary.chartBuckets.reduce(0) { $0 + $1.voiceSeconds }, summary.voiceSeconds, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(summary.buttonRanking.reduce(0) { $0 + $1.value }, summary.pressCount, file: file, line: line)
    }

    private func makeCalendar(timeZone: String = "Asia/Shanghai") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
}
