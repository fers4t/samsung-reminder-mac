import XCTest
@testable import Samsung_Reminder

final class ModelTests: XCTestCase {
    func testReminderMapsLooselyTypedRecord() {
        let record: [String: JSONValue] = [
            "record_id": .string("abc"), "title": .string("Call"), "item_status": .string("2"),
            "favorite": .number(1), "alarm_reminde_time": .number(1_700_000_000_000),
            "mod_timestamp": .number(5), "last_modified_time": .number(0), "rrule": .string("FREQ=DAILY"),
            "location_address": .string("Office"),
        ]
        let reminder = Reminder(record: record)
        XCTAssertEqual(reminder.id, "abc")
        XCTAssertTrue(reminder.completed)
        XCTAssertTrue(reminder.favorite)
        XCTAssertTrue(reminder.repeats)
        XCTAssertTrue(reminder.hasLocation)
        XCTAssertEqual(reminder.categoryID, defaultCategoryID)
        XCTAssertEqual(reminder.dueAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(reminder.modifiedAt, Date(timeIntervalSince1970: 0.005))
    }

    func testAllDayUsesStartTime() {
        let reminder = Reminder(record: ["all_day": .number(1), "start_time": .number(86_400_000), "alarm_reminde_time": .null])
        XCTAssertTrue(reminder.allDay)
        XCTAssertEqual(reminder.dueAt, Date(timeIntervalSince1970: 86_400))
    }

    func testPendingOrdersDatedFirst() {
        func make(_ id: String, due: TimeInterval?, completed: Bool = false) -> Reminder {
            var record: [String: JSONValue] = ["record_id": .string(id), "title": .string(id), "item_status": JSONValue(completed ? 2 : 1)]
            if let due { record["alarm_reminde_time"] = .number(due * 1000) }
            return Reminder(record: record)
        }
        let snapshot = ReminderSnapshot(syncedAt: Date(), reminders: [make("z", due: nil), make("b", due: 20), make("a", due: 10), make("done", due: 1, completed: true)], categories: [])
        XCTAssertEqual(snapshot.pending().map(\.id), ["a", "b", "z"])
        XCTAssertEqual(snapshot.pending(limit: 1).map(\.id), ["a"])
    }

    func testBlankRecordMatchesMobileShape() {
        let record = ReminderService.blankRecord()
        XCTAssertEqual(record.count, 79, "field count must match the mobile schema")
        XCTAssertEqual(record["original_image_7_position"], .null)
    }

    func testDraftTimedWithRepeatAndEarlyAlert() throws {
        var draft = ReminderDraft()
        draft.title = " Call "
        draft.text = "body"
        draft.checklist = [.init(text: "a", done: true), .init(text: "  ", done: false)]
        draft.schedule = .timed(Date(timeIntervalSinceNow: 3600))
        draft.repeatRule = RepeatRule(unit: .week, interval: 2)
        draft.earlyAlert = EarlyAlert(offset: 30, unit: .minute)
        draft.alertType = .strong
        var record = ReminderService.blankRecord()
        try draft.validated().apply(to: &record)
        XCTAssertEqual(record["title"]?.string, "Call")
        XCTAssertEqual(record["has_checkbox"]?.int, 1)
        XCTAssertEqual(record["plainText"]?.string, "a\nbody\n")
        XCTAssertEqual(record["event_type"]?.int, 4)
        XCTAssertEqual(record["alarm_repeat_type"]?.int, 5)
        XCTAssertEqual(record["event_status"]?.int, 1)
        XCTAssertEqual(record["alert_type"]?.int, 17)
        XCTAssertEqual(record["alarm_sound_type"]?.int, 1)
        XCTAssertTrue(record["rrule"]?.string?.hasPrefix("FREQ=WEEKLY;INTERVAL=2;BYDAY=") == true)
        XCTAssertEqual(record["time_alarm_pre_notify"]?.string, "{\"pList\":[{\"u\":\"m\",\"val\":30,\"ver\":1}]}")
        XCTAssertEqual(record["allday_pre_notify"], .null)
        let reminder = Reminder(record: record)
        XCTAssertEqual(reminder.checklist, [.init(text: "a", done: true)])
        XCTAssertEqual(reminder.repeatRule?.unit, .week)
        XCTAssertEqual(reminder.earlyAlert, EarlyAlert(offset: 30, unit: .minute))
        XCTAssertEqual(ReminderDraft(reminder: reminder).repeatRule?.interval, 2)
        // Integral numbers must serialise without a fractional part.
        let data = try JSONEncoder().encode(JSONValue.object(["n": record["event_type"]!]))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"n\":4}")
    }

    func testDraftAllDayAndLocationAndClearing() throws {
        var draft = ReminderDraft()
        draft.title = "Trip"
        draft.schedule = .allDay(Date(timeIntervalSince1970: 1_700_000_000))
        draft.location = ReminderLocation(latitude: 41.0, longitude: 29.0, address: "Office", transition: .leave)
        var record = ReminderService.blankRecord()
        try draft.validated().apply(to: &record)
        XCTAssertEqual(record["all_day"]?.int, 1)
        XCTAssertEqual(record["event_type"]?.int, 9)
        XCTAssertEqual((record["end_time"]?.int ?? 0) - (record["start_time"]?.int ?? 0), 86_400_000)
        XCTAssertEqual((record["start_time"]?.int ?? 1) % 86_400_000, 0, "all-day start is UTC midnight")
        XCTAssertEqual(record["location_transition_type"]?.int, 2)
        XCTAssertEqual(record["radius"], .number(200))
        let reminder = Reminder(record: record)
        XCTAssertTrue(reminder.allDay)
        XCTAssertEqual(reminder.location?.transition, .leave)

        var cleared = ReminderDraft(reminder: reminder)
        cleared.schedule = .none
        cleared.location = nil
        cleared.apply(to: &record)
        XCTAssertEqual(record["event_type"]?.int, 0)
        XCTAssertEqual(record["event_status"]?.int, 0)
        XCTAssertEqual(record["start_time"], .null)
        XCTAssertEqual(record["location_latitude"], .null)
        XCTAssertNil(Reminder(record: record).location)
    }

    func testRepeatRuleRoundTrip() {
        let until = Date(timeIntervalSince1970: 1_800_000_000)
        let rule = RepeatRule(unit: .year, interval: 1, byMonthDay: 5, byMonth: 11, until: until)
        let text = rule.rrule(start: Date())
        XCTAssertEqual(text, "FREQ=YEARLY;INTERVAL=1;BYMONTH=11;BYMONTHDAY=5;UNTIL=20270115T080000Z;WKST=SU")
        let parsed = RepeatRule(rrule: text)
        XCTAssertEqual(parsed?.unit, .year)
        XCTAssertEqual(parsed?.byMonth, 11)
        XCTAssertEqual(parsed?.until, until)
        XCTAssertEqual(RepeatRule(record: ["alarm_repeat_type": .number(2)])?.unit, .week)
        XCTAssertNil(RepeatRule(rrule: "FREQ=BOGUS"))
        XCTAssertThrowsError(try { var d = ReminderDraft(); d.title = "x"; d.location = .init(latitude: 95, longitude: 0, address: ""); return try d.validated() }())
    }

    func testMergeKeepsLocalEditsAndCreatesMadeDuringSync() {
        func rec(_ id: String, _ ts: Int64) -> [String: JSONValue] { ["record_id": .string(id), "mod_timestamp": JSONValue(ts)] }
        let local = ["edited": rec("edited", 200), "stale": rec("stale", 50), "deleted": rec("deleted", 10), "created": rec("created", 150)]
        let fetched = [rec("edited", 100), rec("stale", 120), rec("new", 90)]
        let merged = ReminderService.merge(local: local, fetched: fetched, liveIDs: ["edited", "stale", "new"], syncStart: 140)
        XCTAssertEqual(merged["edited"]?["mod_timestamp"]?.int, 200, "local edit newer than fetched wins")
        XCTAssertEqual(merged["stale"]?["mod_timestamp"]?.int, 120, "fetched newer record replaces cache")
        XCTAssertEqual(merged["new"]?["mod_timestamp"]?.int, 90)
        XCTAssertNotNil(merged["created"], "created after listing started must survive")
        XCTAssertNil(merged["deleted"], "unlisted and old is gone")
    }
}
