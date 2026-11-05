import Foundation

/// Everything the UI and the widget need, written by the app after each sync.
/// Contains no credential. The widget only ever reads this file.
public struct ReminderSnapshot: Codable, Sendable, Equatable {
    public static let formatVersion = 1

    public var version: Int = ReminderSnapshot.formatVersion
    public var syncedAt: Date
    public var reminders: [Reminder]
    public var categories: [ReminderCategory]
    /// True when Samsung reported more records than one page (500) returns.
    public var truncated: Bool

    public init(syncedAt: Date, reminders: [Reminder], categories: [ReminderCategory], truncated: Bool = false) {
        self.syncedAt = syncedAt
        self.reminders = reminders
        self.categories = categories
        self.truncated = truncated
    }

    public static let empty = ReminderSnapshot(syncedAt: .distantPast, reminders: [], categories: [])

    /// Incomplete reminders ordered by due date (undated last), then title.
    public func pending(limit: Int = .max) -> [Reminder] {
        var result = reminders.filter { !$0.completed }
        result.sort { lhs, rhs in
            switch (lhs.dueAt, rhs.dueAt) {
            case let (l?, r?) where l != r: return l < r
            case (nil, .some): return false
            case (.some, nil): return true
            default: return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
        return Array(result.prefix(limit))
    }
}

/// Atomic JSON file in the shared App Group container.
public struct SnapshotStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// App Group id comes from Info.plist (`AppGroupIdentifier`) so the app and
    /// the widget resolve the same container without hard-coding the team prefix.
    public static func shared(bundle: Bundle = .main) -> SnapshotStore? {
        guard let group = bundle.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return SnapshotStore(url: container.appendingPathComponent("snapshot.json", isDirectory: false))
    }

    public func load() throws -> ReminderSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let snapshot = try JSONDecoder.cloud.decode(ReminderSnapshot.self, from: data)
        guard snapshot.version == ReminderSnapshot.formatVersion else { return .empty }
        return snapshot
    }

    public func save(_ snapshot: ReminderSnapshot) throws {
        let data = try JSONEncoder.cloud.encode(snapshot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // .atomic writes to a temp file and renames, so the widget never reads a torn file.
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

public extension JSONEncoder {
    static var cloud: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

public extension JSONDecoder {
    static var cloud: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
