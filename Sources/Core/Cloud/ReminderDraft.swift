import Foundation

/// Every user-editable facet of a reminder, in one value. `apply(to:)` is the
/// single place that knows how Samsung's record fields encode it, for both
/// create and update, mirroring the mobile data model.
public struct ReminderDraft: Hashable, Sendable {
    public enum Schedule: Hashable, Sendable {
        case none
        case timed(Date)
        case allDay(Date)

        public var date: Date? {
            switch self { case .none: nil; case .timed(let d), .allDay(let d): d }
        }
    }

    public var title = ""
    public var text = ""
    public var checklist: [ReminderContent.CheckItem] = []
    public var categoryID = defaultCategoryID
    public var favorite = false
    public var schedule: Schedule = .none
    public var repeatRule: RepeatRule?
    public var earlyAlert: EarlyAlert?
    public var location: ReminderLocation?
    public var alertType: AlertType = .medium

    public init() {}

    public init(reminder: Reminder) {
        title = reminder.title
        text = reminder.text
        checklist = reminder.checklist
        categoryID = reminder.categoryID
        favorite = reminder.favorite
        if let due = reminder.dueAt { schedule = reminder.allDay ? .allDay(due) : .timed(due) }
        repeatRule = reminder.repeatRule
        earlyAlert = reminder.earlyAlert
        location = reminder.location
        alertType = reminder.alertType
    }

    static let maxTitle = 500
    static let maxText = 20_000
    static let maxChecklist = 200

    public func validated() throws -> ReminderDraft {
        var draft = self
        draft.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.title.isEmpty else { throw CloudError.invalidInput("A title is required.") }
        guard draft.title.count <= Self.maxTitle, text.count <= Self.maxText, checklist.count <= Self.maxChecklist
        else { throw CloudError.invalidInput("The reminder is too long.") }
        draft.checklist = checklist.map { .init(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), done: $0.done) }
            .filter { !$0.text.isEmpty }
        if draft.categoryID.isEmpty { draft.categoryID = defaultCategoryID }
        if case .none = schedule { draft.repeatRule = nil; draft.earlyAlert = nil }
        if let location, !(-90...90).contains(location.latitude) || !(-180...180).contains(location.longitude) {
            throw CloudError.invalidInput("The location is invalid.")
        }
        return draft
    }

    /// Writes this draft into a raw Samsung record (new or fetched).
    public func apply(to record: inout [String: JSONValue], now: Int64 = SamsungCloudClient.nowMillis()) {
        record["title"] = .string(title)
        record["text"] = .string(ReminderContent.xml(text: text, checklist: checklist))
        record["plainText"] = .string(ReminderContent.plainText(text: text, checklist: checklist))
        record["has_checkbox"] = JSONValue(checklist.isEmpty ? 0 : 1)
        record["category_id"] = .string(categoryID)
        record["favorite"] = JSONValue(favorite ? 1 : 0)
        record["alert_type"] = JSONValue(alertType.rawValue)
        record["alarm_sound_type"] = JSONValue(alertType.rawValue & 1)
        record["mod_timestamp"] = JSONValue(now)
        record["last_modified_time"] = JSONValue(now)

        let hasLocation = location != nil
        for key in ["alarm_reminde_time", "alarm_repeat_type", "alarm_repeat_weekdays", "alarm_tpo_type", "rrule", "date_rrule",
                    "start_time", "end_time", "all_day", "time_alarm_pre_notify", "allday_pre_notify"] {
            record[key] = .null
        }
        switch schedule {
        case .none:
            record["event_type"] = JSONValue(hasLocation ? 5 : 0)
            record["event_status"] = JSONValue(hasLocation ? 1 : 0)
        case .allDay(let date):
            // Samsung stores the calendar day as UTC midnight of that local date.
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            let local = Calendar.current.dateComponents([.year, .month, .day], from: date)
            let start = Int64((utc.date(from: local) ?? date).timeIntervalSince1970 * 1000)
            record["start_time"] = JSONValue(start)
            record["end_time"] = JSONValue(start + 86_400_000)
            record["all_day"] = JSONValue(1)
            let rrule = repeatRule?.rrule(start: date)
            record["date_rrule"] = JSONValue(rrule)
            record["event_type"] = JSONValue(hasLocation ? 9 : 0)
            record["event_status"] = JSONValue(rrule != nil || start + 86_400_000 > now ? 1 : 3)
            record["allday_pre_notify"] = JSONValue(earlyAlert?.serialized)
        case .timed(let date):
            let millis = Int64(date.timeIntervalSince1970 * 1000)
            record["alarm_reminde_time"] = JSONValue(millis)
            record["alarm_repeat_weekdays"] = JSONValue(0)
            record["alarm_tpo_type"] = JSONValue(0)
            record["time_dismissed"] = JSONValue(0)
            let rrule = repeatRule?.rrule(start: date)
            record["event_status"] = JSONValue(rrule != nil || millis > now ? 1 : 3)
            record["time_alarm_pre_notify"] = JSONValue(earlyAlert?.serialized)
            if let rrule {
                record["rrule"] = .string(rrule)
                record["alarm_repeat_type"] = JSONValue(5)
                record["event_type"] = JSONValue(hasLocation ? 8 : 4)
            } else {
                record["alarm_repeat_type"] = JSONValue(0)
                record["event_type"] = JSONValue(hasLocation ? 8 : 1)
            }
        }

        let locationKeys = ["location_transition_type", "location_latitude", "location_longitude", "location_address",
                            "location_place_of_interest", "location_repeat_type", "location_locality",
                            "unified_profile_type", "unified_profile_name", "radius"]
        guard let location else {
            for key in locationKeys { record[key] = .null }
            return
        }
        record["location_transition_type"] = JSONValue(location.transition.rawValue)
        record["location_latitude"] = .number(location.latitude)
        record["location_longitude"] = .number(location.longitude)
        record["location_address"] = .string(location.address)
        record["location_place_of_interest"] = JSONValue(location.placeName)
        record["location_repeat_type"] = JSONValue(10)
        record["location_locality"] = .null
        record["unified_profile_type"] = JSONValue(0)
        record["unified_profile_name"] = .null
        record["radius"] = .number(location.radius)
        record["event_status"] = JSONValue(1)
    }
}
