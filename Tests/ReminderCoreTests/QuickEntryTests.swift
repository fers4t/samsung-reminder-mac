import XCTest
@testable import Samsung_Reminder

final class QuickEntryTests: XCTestCase {
    // Wednesday 2026-11-04 10:00 local time.
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "tr_TR")
        c.firstWeekday = 2
        return c
    }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 10))! }
    private let lists = [QuickEntryParser.ListOption(id: "w", name: "İş"), .init(id: "h", name: "Home")]

    private func parse(_ text: String) -> QuickEntry {
        QuickEntryParser.parse(text, now: now, calendar: calendar, lists: lists)
    }

    private func components(_ date: Date?) -> (Int, Int, Int, Int) {
        let c = calendar.dateComponents([.month, .day, .hour, .minute], from: date ?? .distantPast)
        return (c.month!, c.day!, c.hour!, c.minute!)
    }

    func testTurkishTomorrowWithTimeListAndImportance() {
        let entry = parse("Ali'yi ara yarın 15:00 #iş !")
        XCTAssertEqual(entry.title, "Ali'yi ara")
        XCTAssertTrue(components(entry.date) == (11, 5, 15, 0))
        XCTAssertTrue(entry.hasTime)
        XCTAssertEqual(entry.categoryID, "w")
        XCTAssertTrue(entry.important)
        XCTAssertEqual(entry.chips.map(\.kind), [.important, .list, .date, .time])
        XCTAssertEqual(entry.chips.last?.label, "15:00")
    }

    func testEnglishWeekdayAndPM() {
        let entry = parse("Send report friday 3pm")
        XCTAssertEqual(entry.title, "Send report")
        XCTAssertTrue(components(entry.date) == (11, 6, 15, 0))
    }

    func testBareTimePastMovesToTomorrow() {
        XCTAssertTrue(components(parse("standup 9'da").date) == (11, 5, 9, 0))
        XCTAssertTrue(components(parse("lunch at 12").date) == (11, 4, 12, 0))
    }

    func testRepeatEveryMondayAndDaily() {
        let monday = parse("gym every monday")
        XCTAssertEqual(monday.repeatUnit, .week)
        XCTAssertEqual(monday.repeatByDay, "MO")
        XCTAssertTrue(components(monday.date) == (11, 9, 0, 0))
        XCTAssertFalse(monday.hasTime)
        let daily = parse("su iç her gün 20:00")
        XCTAssertEqual(daily.repeatUnit, .day)
        XCTAssertEqual(daily.title, "su iç")
        XCTAssertTrue(daily.hasTime)
    }

    func testExplicitDatesRollForward() {
        XCTAssertTrue(components(parse("vergi 12 kasım").date) == (11, 12, 0, 0))
        XCTAssertTrue(components(parse("rent jan 5").date) == (1, 5, 0, 0))
        XCTAssertEqual(calendar.component(.year, from: parse("rent jan 5").date!), 2027)
        XCTAssertTrue(components(parse("fatura 20.11").date) == (11, 20, 0, 0), "tr_TR is day-first")
    }

    func testNumbersThatAreNotTimesStayInTitle() {
        let entry = parse("2 kutu süt al")
        XCTAssertEqual(entry.title, "2 kutu süt al")
        XCTAssertNil(entry.date)
        XCTAssertTrue(entry.chips.isEmpty)
    }

    func testUnknownListStaysInTitleAndIgnoringDropsChip() {
        XCTAssertEqual(parse("call #nobody").title, "call #nobody")
        let entry = QuickEntryParser.parse("pay 12 kasım", now: now, calendar: calendar, ignoring: [.date])
        XCTAssertEqual(entry.title, "pay 12 kasım")
        XCTAssertNil(entry.date)
    }

    func testDraftFromEntry() {
        let draft = ReminderDraft(entry: parse("dentist tomorrow 9:30 #home"))
        XCTAssertEqual(draft.categoryID, "h")
        guard case .timed(let date) = draft.schedule else { return XCTFail("expected timed") }
        XCTAssertTrue(components(date) == (11, 5, 9, 30))
        XCTAssertEqual(ReminderDraft(entry: parse("vitamins daily")).repeatRule?.unit, .day)
    }
}
