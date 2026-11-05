import Foundation

/// Samsung's protected default list. It has no category record of its own.
public let defaultCategoryID = "LOCAL_SPACE"

public struct Reminder: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var title: String
    public var text: String
    public var checklist: [ReminderContent.CheckItem]
    public var completed: Bool
    public var favorite: Bool
    public var categoryID: String
    public var allDay: Bool
    /// Fire time for timed reminders, or the day start for all-day reminders.
    public var dueAt: Date?
    public var hasLocation: Bool
    public var locationAddress: String?
    public var repeats: Bool
    public var modifiedAt: Date
    /// Samsung's cloud revision clock; needed verbatim to detect changes between syncs.
    public var modTimestamp: Int64

    public init(record: [String: JSONValue]) {
        id = record["record_id"]?.string ?? ""
        title = record["title"]?.string ?? ""
        text = ReminderContent.text(record: record)
        checklist = ReminderContent.checklist(record: record)
        completed = record["item_status"]?.int == 2
        favorite = record["favorite"]?.int == 1
        categoryID = record["category_id"]?.string ?? defaultCategoryID
        allDay = record["all_day"]?.bool ?? false
        let millis = allDay
            ? (record["start_time"]?.int ?? record["alarm_reminde_time"]?.int)
            : (record["alarm_reminde_time"]?.int ?? record["start_time"]?.int)
        dueAt = millis.flatMap(Reminder.date(fromMillis:))
        hasLocation = (record["location_transition_type"]?.int ?? 0) > 0
            || !(record["location_latitude"]?.isNull ?? true)
            || !(record["location_address"]?.string?.isEmpty ?? true)
        locationAddress = record["location_address"]?.string
        let rrule = record["rrule"]?.string ?? record["date_rrule"]?.string
        repeats = !(rrule?.isEmpty ?? true) || (record["alarm_repeat_type"]?.int ?? 0) > 0
        modTimestamp = record["mod_timestamp"]?.int ?? 0
        let modified = record["last_modified_time"]?.int ?? 0
        modifiedAt = Reminder.date(fromMillis: modified > 0 ? modified : modTimestamp) ?? .distantPast
    }

    static func date(fromMillis millis: Int64) -> Date? {
        millis > 0 ? Date(timeIntervalSince1970: TimeInterval(millis) / 1000) : nil
    }
}

public struct ReminderCategory: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    /// 0...7, Samsung's fixed list palette.
    public var color: Int
    public var iconIndex: Int
    public var order: Int
    public var modTimestamp: Int64

    public init(record: [String: JSONValue]) {
        id = record["record_id"]?.string ?? ""
        name = record["name"]?.string ?? "Untitled"
        color = Int(record["color"]?.int ?? 0)
        iconIndex = Int(record["icon_index"]?.int ?? 0)
        order = Int(record["order"]?.int ?? 0)
        modTimestamp = record["mod_timestamp"]?.int ?? 0
    }

    public init(id: String, name: String, color: Int = 0, iconIndex: Int = 0, order: Int = 0) {
        self.id = id; self.name = name; self.color = color; self.iconIndex = iconIndex; self.order = order
        modTimestamp = 0
    }
}
