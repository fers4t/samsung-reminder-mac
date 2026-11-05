import Foundation

/// Owns the credential and the snapshot. All cloud I/O goes through here so
/// there is exactly one writer of the snapshot file and one 401 handler.
public actor ReminderService {
    public let store: SnapshotStore
    private let keychain: KeychainStore
    private var credential: CloudCredential?
    /// The raw records from the last sync, keyed by id, so edits can round-trip
    /// every field Samsung expects without a second fetch. Bounded by the 500-record page.
    private var rawReminders: [String: [String: JSONValue]] = [:]
    public private(set) var snapshot: ReminderSnapshot
    private var syncInFlight: Task<ReminderSnapshot, Error>?

    public init(store: SnapshotStore, keychain: KeychainStore = KeychainStore()) {
        self.store = store
        self.keychain = keychain
        self.credential = try? keychain.load()
        self.snapshot = (try? store.load()) ?? .empty
    }

    public var isConnected: Bool { credential != nil }
    public var accountHint: String? { credential?.maskedHint }
    public var accountEmail: String? { credential?.accountEmail }

    // MARK: Connection

    /// Validates, probes the reminder table once, then persists.
    public func connect(_ candidate: CloudCredential) async throws {
        let valid = try candidate.validated()
        _ = try await SamsungCloudClient(credential: valid).list(table: SamsungCloudClient.reminderTable, limit: 1)
        try keychain.save(valid)
        credential = valid
    }

    public func disconnect() throws {
        syncInFlight?.cancel()
        credential = nil
        rawReminders = [:]
        snapshot = .empty
        try keychain.delete()
        try store.clear()
    }

    private func client() throws -> SamsungCloudClient {
        guard let credential else { throw CloudError.notConnected }
        return SamsungCloudClient(credential: credential)
    }

    /// Runs `body`; on 401/403 drops the credential so the UI shows "reconnect".
    private func authorized<T: Sendable>(_ body: (SamsungCloudClient) async throws -> T) async throws -> T {
        do {
            return try await body(try client())
        } catch CloudError.unauthorized {
            credential = nil
            try? keychain.delete()
            throw CloudError.unauthorized
        }
    }

    // MARK: Sync

    /// Incremental: compares `mod_timestamp` from the cheap listing with what we
    /// hold and fetches only new/changed records. Concurrent callers share one run.
    @discardableResult
    public func sync() async throws -> ReminderSnapshot {
        if let syncInFlight { return try await syncInFlight.value }
        let task = Task { try await performSync() }
        syncInFlight = task
        defer { syncInFlight = nil }
        return try await task.value
    }

    private func performSync() async throws -> ReminderSnapshot {
        try await authorized { client in
            let syncStart = SamsungCloudClient.nowMillis()
            let listing = try await client.list(table: SamsungCloudClient.reminderTable)
            let changed = listing.records
                .filter { rawReminders[$0.id]?["mod_timestamp"]?.int != $0.modTimestamp }
                .map(\.id)
            let fetched = try await client.get(table: SamsungCloudClient.reminderTable, ids: changed)
            try Task.checkCancellation()
            // The actor is re-entrant across those awaits: a local edit or create may
            // have landed meanwhile, so merge instead of overwriting.
            rawReminders = Self.merge(local: rawReminders, fetched: fetched,
                                      liveIDs: Set(listing.records.map(\.id)), syncStart: syncStart)

            // Categories are few; a full re-read is cheaper than tracking them.
            let categoryIDs = try await client.list(table: SamsungCloudClient.categoryTable, limit: 100).records.map(\.id)
            let categories = try await client.get(table: SamsungCloudClient.categoryTable, ids: categoryIDs)
                .map(ReminderCategory.init(record:))
                .sorted { ($0.order, $0.name) < ($1.order, $1.name) }

            let reminders = rawReminders.values.map(Reminder.init(record:)).sorted { $0.modifiedAt > $1.modifiedAt }
            let result = ReminderSnapshot(syncedAt: Date(), reminders: reminders, categories: categories, truncated: listing.hasMore)
            try store.save(result)
            snapshot = result
            return result
        }
    }

    /// Keeps the newer of local vs fetched per id; drops ids Samsung no longer
    /// lists unless they were written locally after the listing started.
    static func merge(local: [String: [String: JSONValue]], fetched: [[String: JSONValue]],
                      liveIDs: Set<String>, syncStart: Int64) -> [String: [String: JSONValue]] {
        var result = local.filter { liveIDs.contains($0.key) || ($0.value["mod_timestamp"]?.int ?? 0) >= syncStart }
        for record in fetched {
            guard let id = record["record_id"]?.string else { continue }
            let localTS = result[id]?["mod_timestamp"]?.int ?? -1
            if (record["mod_timestamp"]?.int ?? 0) >= localTS { result[id] = record }
        }
        return result
    }

    // MARK: Mutations

    public struct NewReminder: Sendable {
        public var title: String
        public var text: String
        public var dueAt: Date?
        public var categoryID: String
        public init(title: String, text: String = "", dueAt: Date? = nil, categoryID: String = defaultCategoryID) {
            self.title = title; self.text = text; self.dueAt = dueAt; self.categoryID = categoryID
        }
    }

    static let maxTitleLength = 500
    static let maxTextLength = 20_000

    public func create(_ input: NewReminder) async throws -> Reminder {
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CloudError.invalidInput("A title is required.") }
        guard title.count <= Self.maxTitleLength, input.text.count <= Self.maxTextLength else {
            throw CloudError.invalidInput("The reminder is too long.")
        }
        var record = Self.blankRecord(title: title, text: input.text, categoryID: input.categoryID)
        if let due = input.dueAt { Self.applyTimedSchedule(&record, due: due) }
        return try await upload(record)
    }

    public func setCompleted(_ id: String, _ completed: Bool) async throws -> Reminder {
        try await modify(id) { $0["item_status"] = JSONValue(completed ? 2 : 1) }
    }

    public func setFavorite(_ id: String, _ favorite: Bool) async throws -> Reminder {
        try await modify(id) { $0["favorite"] = JSONValue(favorite ? 1 : 0) }
    }

    /// Requires `confirmID == id` as a guard against accidental deletes from any caller.
    public func delete(_ id: String, confirmID: String) async throws {
        guard id == confirmID, !id.isEmpty else { throw CloudError.invalidInput("Delete confirmation did not match.") }
        try await authorized { client in
            try await client.delete(table: SamsungCloudClient.reminderTable, id: id)
        }
        rawReminders[id] = nil
        snapshot.reminders.removeAll { $0.id == id }
        try store.save(snapshot)
    }

    private func modify(_ id: String, _ change: (inout [String: JSONValue]) -> Void) async throws -> Reminder {
        var record: [String: JSONValue]
        if let cached = rawReminders[id] {
            record = cached
        } else {
            guard let fetched = try await authorized({ try await $0.getOne(table: SamsungCloudClient.reminderTable, id: id) })
            else { throw CloudError.notFound }
            record = fetched
        }
        change(&record)
        let now = JSONValue(SamsungCloudClient.nowMillis())
        record["mod_timestamp"] = now
        record["last_modified_time"] = now
        return try await upload(record)
    }

    private func upload(_ record: [String: JSONValue]) async throws -> Reminder {
        try await authorized { client in
            try await client.upload(table: SamsungCloudClient.reminderTable, record: record)
        }
        let reminder = Reminder(record: record)
        rawReminders[reminder.id] = record
        if let index = snapshot.reminders.firstIndex(where: { $0.id == reminder.id }) {
            snapshot.reminders[index] = reminder
        } else {
            snapshot.reminders.insert(reminder, at: 0)
        }
        try store.save(snapshot)
        return reminder
    }

    // MARK: Record construction (mirrors the mobile data model)

    static func blankRecord(title: String, text: String, categoryID: String) -> [String: JSONValue] {
        let now = JSONValue(SamsungCloudClient.nowMillis())
        var record: [String: JSONValue] = [
            "record_id": .string(UUID().uuidString.lowercased()), "mod_timestamp": now, "event_type": JSONValue(0),
            "item_status": JSONValue(1), "item_color": JSONValue(0), "title": .string(title), "time_create": now,
            "last_modified_time": now, "root_reminder_record_id": .null,
            "category_id": .string(categoryID), "favorite": JSONValue(0), "weight": now,
            "text": .string(ReminderContent.xml(text: text, checklist: [])),
            "plainText": .string(ReminderContent.plainText(text: text, checklist: [])),
            "utterance": .string(""), "has_checkbox": JSONValue(0), "has_attached_file": JSONValue(0),
        ]
        let nullKeys = [
            "alarm_repeat_type", "alarm_repeat_weekdays", "alarm_reminde_time", "alarm_tpo_type", "rrule", "date_rrule",
            "time_alarm_pre_notify", "allday_pre_notify", "time_alarm_notify_info", "allday_alarm_notify_info",
            "location_transition_type", "location_latitude", "location_longitude", "location_address",
            "location_place_of_interest", "location_repeat_type", "location_locality", "unified_profile_type",
            "unified_profile_name", "radius", "occasion_key", "occasion_type", "occasion_event_type",
            "occasion_event_repeat_type", "occasion_name", "occasion_info1", "occasion_info2", "occasion_info3",
            "during_option_start_time", "during_option_end_time", "time_dismissed", "event_status", "alarm_sound_type",
            "alert_type", "start_time", "end_time", "all_day", "app_card_type", "app_card_content_intent",
            "app_card_info_1", "app_card_info_2", "app_card_info_3", "web_title", "web_description", "web_thumbnail", "url",
        ]
        for key in nullKeys { record[key] = .null }
        for index in 0..<8 {
            record["original_image_\(index)"] = .null
            record["original_image_\(index)_position"] = .null
        }
        return record
    }

    /// One-shot timed alarm, exactly as the phone writes it (event_type 1).
    static func applyTimedSchedule(_ record: inout [String: JSONValue], due: Date) {
        let millis = Int64(due.timeIntervalSince1970 * 1000)
        record["alarm_reminde_time"] = JSONValue(millis)
        record["alarm_repeat_type"] = JSONValue(0)
        record["alarm_repeat_weekdays"] = JSONValue(0)
        record["alarm_tpo_type"] = JSONValue(0)
        record["time_dismissed"] = JSONValue(0)
        record["event_type"] = JSONValue(1)
        record["event_status"] = JSONValue(millis > SamsungCloudClient.nowMillis() ? 1 : 3)
        record["start_time"] = .null
        record["end_time"] = .null
        record["all_day"] = .null
    }
}
