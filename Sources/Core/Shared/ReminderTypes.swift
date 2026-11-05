import Foundation

/// "Remind me N units before". Samsung stores it as JSON text:
/// `{"pList":[{"val":N,"u":"d","ver":1,"e":minutesOfDay?}]}`.
public struct EarlyAlert: Hashable, Codable, Sendable {
    public enum Unit: String, Codable, CaseIterable, Sendable {
        case minute = "m", hour = "h", day = "d", week = "w", month = "mo", year = "y"
        public var label: String {
            switch self {
            case .minute: "minutes"; case .hour: "hours"; case .day: "days"
            case .week: "weeks"; case .month: "months"; case .year: "years"
            }
        }
    }
    public var offset: Int
    public var unit: Unit
    /// Minutes after midnight for all-day reminders (-1439...1439), when set.
    public var exactTime: Int?

    public init(offset: Int, unit: Unit, exactTime: Int? = nil) {
        self.offset = offset; self.unit = unit; self.exactTime = exactTime
    }

    public init?(record: [String: JSONValue]) {
        let allDay = record["all_day"]?.bool ?? false
        guard let raw = record[allDay ? "allday_pre_notify" : "time_alarm_pre_notify"] else { return nil }
        let parsed: JSONValue
        switch raw {
        case .string(let text):
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return nil }
            parsed = value
        case .object: parsed = raw
        default: return nil
        }
        guard let item = parsed["pList"].array?.first, let offset = item["val"].int, offset >= 1,
              let unit = item["u"].string.flatMap(Unit.init(rawValue:)) else { return nil }
        self.offset = Int(offset); self.unit = unit; exactTime = item["e"].int.map(Int.init)
    }

    public var serialized: String {
        var item: [String: JSONValue] = ["val": JSONValue(min(max(offset, 1), 999)), "u": .string(unit.rawValue), "ver": JSONValue(1)]
        if let exactTime { item["e"] = JSONValue(min(max(exactTime, -1439), 1439)) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try! encoder.encode(JSONValue.object(["pList": .array([.object(item)])]))
        return String(decoding: data, as: UTF8.self)
    }
}

/// Recurrence, stored as an RFC 5545 RRULE string (`rrule` for timed, `date_rrule` for all-day).
public struct RepeatRule: Hashable, Codable, Sendable {
    public enum Unit: String, Codable, CaseIterable, Sendable {
        case minute = "MINUTELY", hour = "HOURLY", day = "DAILY", week = "WEEKLY", month = "MONTHLY", year = "YEARLY"
        public var label: String {
            switch self {
            case .minute: "minute"; case .hour: "hour"; case .day: "day"; case .week: "week"; case .month: "month"; case .year: "year"
            }
        }
    }
    public static let weekdays = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]

    public var unit: Unit
    public var interval: Int = 1
    public var byDay: String?
    public var byMonthDay: Int?
    public var byMonth: Int?
    public var count: Int?
    public var until: Date?

    public init(unit: Unit, interval: Int = 1, byDay: String? = nil, byMonthDay: Int? = nil, byMonth: Int? = nil, count: Int? = nil, until: Date? = nil) {
        self.unit = unit; self.interval = interval; self.byDay = byDay; self.byMonthDay = byMonthDay
        self.byMonth = byMonth; self.count = count; self.until = until
    }

    /// Parses Samsung's RRULE, or the legacy `alarm_repeat_type` code.
    public init?(record: [String: JSONValue]) {
        let rrule = record["rrule"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? record["date_rrule"]?.string ?? ""
        if !rrule.isEmpty {
            guard let parsed = RepeatRule(rrule: rrule) else { return nil }
            self = parsed
            return
        }
        switch record["alarm_repeat_type"]?.int {
        case 1: unit = .day
        case 2: unit = .week
        case 3: unit = .month
        case 4: unit = .year
        case 6: unit = .minute
        case 7: unit = .hour
        default: return nil
        }
    }

    public init?(rrule: String) {
        var parts: [String: String] = [:]
        for part in rrule.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { parts[String(pair[0])] = String(pair[1]) }
        }
        guard let unit = parts["FREQ"].flatMap(Unit.init(rawValue:)) else { return nil }
        self.unit = unit
        interval = parts["INTERVAL"].flatMap(Int.init) ?? 1
        byDay = parts["BYDAY"]
        byMonthDay = parts["BYMONTHDAY"].flatMap(Int.init)
        byMonth = parts["BYMONTH"].flatMap(Int.init)
        count = parts["COUNT"].flatMap(Int.init)
        until = parts["UNTIL"].flatMap(Self.rruleDate.date(from:))
    }

    public func rrule(start: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var parts = ["FREQ=\(unit.rawValue)", "INTERVAL=\(min(max(interval, 1), 999))"]
        switch unit {
        case .week:
            let weekday = (calendar.component(.weekday, from: start) + 5) % 7 // Monday = 0
            let day = byDay.flatMap { Self.weekdays.contains($0) ? $0 : nil } ?? Self.weekdays[weekday]
            parts.append("BYDAY=\(day)")
        case .month:
            parts.append("BYMONTHDAY=\(min(max(byMonthDay ?? calendar.component(.day, from: start), 1), 31))")
        case .year:
            parts.append("BYMONTH=\(min(max(byMonth ?? calendar.component(.month, from: start), 1), 12))")
            parts.append("BYMONTHDAY=\(min(max(byMonthDay ?? calendar.component(.day, from: start), 1), 31))")
        default: break
        }
        if let count { parts.append("COUNT=\(min(max(count, 1), 9999))") }
        else if let until { parts.append("UNTIL=\(Self.rruleDate.string(from: until))") }
        parts.append("WKST=SU")
        return parts.joined(separator: ";")
    }

    static let rruleDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()
}

public struct ReminderLocation: Hashable, Codable, Sendable {
    public enum Transition: Int, Codable, CaseIterable, Sendable {
        case arrive = 1, leave = 2
        public var label: String { self == .arrive ? "When I arrive" : "When I leave" }
    }
    public var latitude: Double
    public var longitude: Double
    public var address: String
    public var placeName: String?
    public var transition: Transition
    public var radius: Double

    public init(latitude: Double, longitude: Double, address: String, placeName: String? = nil, transition: Transition = .arrive, radius: Double = 200) {
        self.latitude = latitude; self.longitude = longitude; self.address = address
        self.placeName = placeName; self.transition = transition; self.radius = radius
    }

    public init?(record: [String: JSONValue]) {
        let hasLocation = (record["location_transition_type"]?.int ?? 0) > 0
            || !(record["location_latitude"]?.isNull ?? true)
            || !(record["location_address"]?.string?.isEmpty ?? true)
        guard hasLocation else { return nil }
        latitude = Self.double(record["location_latitude"]) ?? 0
        longitude = Self.double(record["location_longitude"]) ?? 0
        address = record["location_address"]?.string ?? ""
        placeName = record["location_place_of_interest"]?.string
        transition = Transition(rawValue: Int(record["location_transition_type"]?.int ?? 1)) ?? .arrive
        radius = Self.double(record["radius"]) ?? 200
    }

    static func double(_ value: JSONValue?) -> Double? {
        switch value {
        case .number(let d): return d
        case .string(let s): return Double(s)
        default: return nil
        }
    }
}

/// Samsung's three alert strengths.
public enum AlertType: Int, Codable, CaseIterable, Sendable {
    case weak = 0, medium = 16, strong = 17
    public var label: String {
        switch self { case .weak: "Silent"; case .medium: "Notification"; case .strong: "Alarm" }
    }
}
