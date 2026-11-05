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

    func testBlankRecordMatchesMobileShapeAndTimedSchedule() throws {
        var record = ReminderService.blankRecord(title: "T", text: "body", categoryID: "cat")
        XCTAssertEqual(record.count, 79, "field count must match the mobile schema")
        XCTAssertEqual(record["plainText"], .string("body\n"))
        XCTAssertEqual(record["original_image_7_position"], .null)
        ReminderService.applyTimedSchedule(&record, due: Date(timeIntervalSinceNow: 3600))
        XCTAssertEqual(record["event_type"]?.int, 1)
        XCTAssertEqual(record["event_status"]?.int, 1)
        XCTAssertEqual(record["alarm_repeat_type"]?.int, 0)
        let reminder = Reminder(record: record)
        XCTAssertEqual(reminder.text, "body")
        XCTAssertNotNil(reminder.dueAt)
        // Integral numbers must serialise without a fractional part.
        let data = try JSONEncoder().encode(JSONValue.object(["n": record["event_type"]!]))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"n\":1}")
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
