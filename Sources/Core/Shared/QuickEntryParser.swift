import Foundation

/// Turns "Ali'yi ara yarın 15:00 #iş !" into a title plus schedule, repeat, list and importance.
/// Pure and locale-aware (Turkish + English), so capture needs no form.
public struct QuickEntry: Equatable, Sendable {
    public enum ChipKind: String, Sendable, CaseIterable { case date, time, repeatRule, list, important }

    public struct Chip: Equatable, Sendable {
        public let kind: ChipKind
        public let label: String
    }

    public var title: String
    public var date: Date?
    public var hasTime: Bool
    public var repeatUnit: RepeatRule.Unit?
    public var repeatByDay: String?
    public var categoryID: String?
    public var important: Bool
    public var chips: [Chip]
}

public enum QuickEntryParser {
    public struct ListOption: Sendable { public let id: String; public let name: String
        public init(id: String, name: String) { self.id = id; self.name = name } }

    private static let weekdays: [(names: [String], index: Int)] = [
        (["monday", "mon", "pazartesi", "pzt"], 2), (["tuesday", "tue", "salı", "sali", "sal"], 3),
        (["wednesday", "wed", "çarşamba", "carsamba", "çar"], 4), (["thursday", "thu", "perşembe", "persembe", "per"], 5),
        (["friday", "fri", "cuma", "cum"], 6), (["saturday", "sat", "cumartesi", "cmt"], 7), (["sunday", "sun", "pazar", "paz"], 1),
    ]
    private static let months: [(names: [String], number: Int)] = [
        (["january", "jan", "ocak", "oca"], 1), (["february", "feb", "şubat", "subat", "şub"], 2), (["march", "mar", "mart"], 3),
        (["april", "apr", "nisan", "nis"], 4), (["may", "mayıs", "mayis"], 5), (["june", "jun", "haziran", "haz"], 6),
        (["july", "jul", "temmuz", "tem"], 7), (["august", "aug", "ağustos", "agustos", "ağu"], 8),
        (["september", "sep", "sept", "eylül", "eylul", "eyl"], 9), (["october", "oct", "ekim", "eki"], 10),
        (["november", "nov", "kasım", "kasim", "kas"], 11), (["december", "dec", "aralık", "aralik", "ara"], 12),
    ]

    /// `ignoring` lets the UI drop a chip the parser got wrong; that token then stays in the title.
    public static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current,
                             lists: [ListOption] = [], ignoring: Set<QuickEntry.ChipKind> = []) -> QuickEntry {
        var text = " " + input.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression) + " "
        var chips: [QuickEntry.Chip] = []
        var day: Date?
        var time: (hour: Int, minute: Int)?
        var repeatUnit: RepeatRule.Unit?
        var repeatByDay: String?
        var categoryID: String?
        var important = false

        func take(_ pattern: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let whole = Range(match.range, in: text) else { return nil }
            let groups = (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
            text.replaceSubrange(whole, with: " ")
            return groups
        }

        // Importance: a trailing "!" or the word itself.
        if !ignoring.contains(.important), take(#"\s(!+|önemli|important)\s*$"#) != nil {
            important = true
            chips.append(.init(kind: .important, label: "Important"))
        }

        // List: "#work" or "#iş" against known lists (prefix match, longest name wins).
        if !ignoring.contains(.list), let groups = take(#"\s#([^\s#]+)\s"#) {
            let needle = groups[0]
            // Locale-independent prefix match: Turkish İ/ı and accents must not break "#iş" against "İş".
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .anchored]
            if let hit = lists.filter({ $0.name.range(of: needle, options: options) != nil }).max(by: { $0.name.count < $1.name.count }) {
                categoryID = hit.id
                chips.append(.init(kind: .list, label: hit.name))
            } else {
                text += "#\(groups[0]) "
            }
        }

        // Repeat: "every day" / "her gün" / "daily" / "every monday".
        if !ignoring.contains(.repeatRule) {
            let weekdayAlternation = weekdays.flatMap(\.names).joined(separator: "|")
            if let groups = take(#"\s(?:every|her)\s(day|week|month|year|gün|hafta|ay|yıl|yil|\#(weekdayAlternation))\s"#) {
                let word = groups[0].lowercased()
                switch word {
                case "day", "gün": repeatUnit = .day
                case "week", "hafta": repeatUnit = .week
                case "month", "ay": repeatUnit = .month
                case "year", "yıl", "yil": repeatUnit = .year
                default:
                    if let weekday = weekdays.first(where: { $0.names.contains(word) }) {
                        repeatUnit = .week
                        repeatByDay = RepeatRule.weekdays[(weekday.index + 5) % 7]
                        day = next(weekday: weekday.index, from: now, calendar: calendar)
                    }
                }
            } else if let groups = take(#"\s(daily|weekly|monthly|yearly|günlük|gunluk|haftalık|haftalik|aylık|aylik|yıllık|yillik)\s"#) {
                switch groups[0].lowercased() {
                case "daily", "günlük", "gunluk": repeatUnit = .day
                case "weekly", "haftalık", "haftalik": repeatUnit = .week
                case "monthly", "aylık", "aylik": repeatUnit = .month
                default: repeatUnit = .year
                }
            }
            if let repeatUnit {
                chips.append(.init(kind: .repeatRule, label: repeatByDay.map { "Every \(weekdayName($0))" } ?? "Every \(repeatUnit.label)"))
            }
        }

        // Time: "15:00", "15.30", "3pm", "at 9", "saat 9", "9'da".
        if !ignoring.contains(.time) {
            // "20.11" is a date in Turkish writing; a dotted pair counts as a time only with a cue
            // (at/saat, am/pm, 'de suffix) or when the minutes cannot be a month.
            let patterns: [(pattern: String, hasMinutes: Bool)] = [
                (#"\s(?:at\s|saat\s)?(\d{1,2}):(\d{2})\s*(am|pm)?(?:'?[dt][ae])?\s"#, true),
                (#"\s(?:at\s|saat\s)(\d{1,2})\.(\d{2})\s*(am|pm)?(?:'?[dt][ae])?\s"#, true),
                (#"\s(\d{1,2})\.(\d{2})\s*(am|pm|'?[dt][ae])\s"#, true),
                (#"\s(\d{1,2})\.(1[3-9]|[2-5]\d)()\s"#, true),
                (#"\s(\d{1,2})\s*()(am|pm)\s"#, false),
                (#"\s(?:at|saat)\s(\d{1,2})()()\s"#, false),
                (#"\s(\d{1,2})'?[dt][ae]()()\s"#, false),
            ]
            for item in patterns {
                guard let groups = take(item.pattern) else { continue }
                var hour = Int(groups[0]) ?? 0
                let minute = item.hasMinutes ? Int(groups[1]) ?? 0 : 0
                let meridiem = groups[2].lowercased().hasPrefix("a") || groups[2].lowercased().hasPrefix("p") ? String(groups[2].lowercased().prefix(2)) : ""
                if meridiem == "pm", hour < 12 { hour += 12 }
                if meridiem == "am", hour == 12 { hour = 0 }
                guard (0...23).contains(hour), (0...59).contains(minute) else { break }
                time = (hour, minute)
                break
            }
        }

        // Date words and explicit dates.
        if !ignoring.contains(.date) {
            if take(#"\s(tonight|bu akşam|bu aksam)\s"#) != nil {
                day = calendar.startOfDay(for: now)
                if time == nil { time = (20, 0) }
            } else if take(#"\s(day after tomorrow|öbür gün|obur gun)\s"#) != nil {
                day = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now))
            } else if take(#"\s(tomorrow|yarın|yarin)\s"#) != nil {
                day = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            } else if take(#"\s(today|bugün|bugun)\s"#) != nil {
                day = calendar.startOfDay(for: now)
            } else if take(#"\s(next week|haftaya|gelecek hafta)\s"#) != nil {
                day = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: now))
            } else if day == nil {
                let weekdayAlternation = weekdays.flatMap(\.names).joined(separator: "|")
                if let groups = take(#"\s(?:on\s|next\s|bu\s|gelecek\s)?(\#(weekdayAlternation))(?:\s(?:günü|gunu))?\s"#),
                   let weekday = weekdays.first(where: { $0.names.contains(groups[0].lowercased()) }) {
                    day = next(weekday: weekday.index, from: now, calendar: calendar)
                }
            }
            if day == nil {
                let monthAlternation = months.flatMap(\.names).joined(separator: "|")
                // "12 kasım" / "nov 12" / "12/11" / "12.11.2026"
                if let groups = take(#"\s(\d{1,2})\s(\#(monthAlternation))(?:\s(\d{4}))?\s"#),
                   let month = months.first(where: { $0.names.contains(groups[1].lowercased()) }) {
                    day = date(day: Int(groups[0]) ?? 0, month: month.number, year: Int(groups[2]), now: now, calendar: calendar)
                } else if let groups = take(#"\s(\#(monthAlternation))\s(\d{1,2})(?:,?\s(\d{4}))?\s"#),
                          let month = months.first(where: { $0.names.contains(groups[0].lowercased()) }) {
                    day = date(day: Int(groups[1]) ?? 0, month: month.number, year: Int(groups[2]), now: now, calendar: calendar)
                } else if let groups = take(#"\s(\d{1,2})[./](\d{1,2})(?:[./](\d{4}))?\s"#) {
                    let first = Int(groups[0]) ?? 0, second = Int(groups[1]) ?? 0
                    let monthFirst = Self.monthFirst(calendar)
                    day = date(day: monthFirst ? second : first, month: monthFirst ? first : second, year: Int(groups[2]), now: now, calendar: calendar)
                }
            }
        }

        // A bare time means today if still ahead, otherwise tomorrow.
        if let time, day == nil {
            let today = calendar.startOfDay(for: now)
            let candidate = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: today) ?? today
            day = candidate > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
        }
        var resolved: Date?
        if let day {
            resolved = time.flatMap { calendar.date(bySettingHour: $0.hour, minute: $0.minute, second: 0, of: day) } ?? day
            chips.append(.init(kind: .date, label: label(for: day, now: now, calendar: calendar)))
            if let time { chips.append(.init(kind: .time, label: String(format: "%02d:%02d", time.hour, time.minute))) }
        }

        let title = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return QuickEntry(title: title, date: resolved, hasTime: time != nil, repeatUnit: repeatUnit, repeatByDay: repeatByDay,
                          categoryID: categoryID, important: important, chips: chips)
    }

    private static func next(weekday: Int, from now: Date, calendar: Calendar) -> Date? {
        calendar.nextDate(after: calendar.startOfDay(for: now), matching: DateComponents(weekday: weekday), matchingPolicy: .nextTime)
    }

    private static func date(day: Int, month: Int, year: Int?, now: Date, calendar: Calendar) -> Date? {
        guard (1...31).contains(day), (1...12).contains(month) else { return nil }
        var components = DateComponents(year: year ?? calendar.component(.year, from: now), month: month, day: day)
        guard var date = calendar.date(from: components), calendar.component(.day, from: date) == day else { return nil }
        if year == nil, date < calendar.startOfDay(for: now) {
            components.year! += 1
            date = calendar.date(from: components) ?? date
        }
        return date
    }

    private static func monthFirst(_ calendar: Calendar) -> Bool {
        let format = DateFormatter.dateFormat(fromTemplate: "dMy", options: 0, locale: calendar.locale ?? .current) ?? "d/M/y"
        return (format.firstIndex(of: "M") ?? format.endIndex) < (format.firstIndex(of: "d") ?? format.endIndex)
    }

    private static func weekdayName(_ code: String) -> String {
        ["MO": "Monday", "TU": "Tuesday", "WE": "Wednesday", "TH": "Thursday", "FR": "Friday", "SA": "Saturday", "SU": "Sunday"][code] ?? code
    }

    static func label(for day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(day, inSameDayAs: tomorrow) { return "Tomorrow" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate(calendar.isDate(day, equalTo: now, toGranularity: .year) ? "EEE d MMM" : "EEE d MMM yyyy")
        return formatter.string(from: day)
    }
}
