import Foundation
import Observation
import AppKit
import SwiftUI
import WidgetKit
import os

/// UI state plus the refresh loop. Everything here runs on the main actor;
/// cloud work is delegated to the `ReminderService` actor.
@MainActor
@Observable
final class AppModel {
    enum Filter: Hashable {
        case all, today, upcoming, favorites, completed, category(String)
    }

    private(set) var snapshot: ReminderSnapshot = .empty
    private(set) var isConnected = false
    private(set) var accountHint: String?
    private(set) var accountEmail: String?
    private(set) var isSyncing = false
    private(set) var lastError: String?
    private(set) var storeUnavailable = false

    var filter: Filter = .all
    var searchText = ""
    var selectedReminderID: String?
    var showNewReminder = false
    var showConnect = false

    /// Minutes between background refreshes; persisted per user.
    var refreshIntervalMinutes: Int {
        didSet {
            UserDefaults.standard.set(refreshIntervalMinutes, forKey: Self.intervalKey)
            restartRefreshLoop()
        }
    }
    var notificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: Self.notificationsKey)
            Task { await rescheduleNotifications() }
        }
    }

    private static let intervalKey = "refreshIntervalMinutes"
    private static let notificationsKey = "notificationsEnabled"
    private static let logger = Logger(subsystem: "SamsungReminder", category: "app")

    private let service: ReminderService?
    private let notifications = NotificationScheduler()
    private var refreshTask: Task<Void, Never>?
    private var started = false

    init() {
        let defaults = UserDefaults.standard
        let interval = defaults.integer(forKey: Self.intervalKey)
        refreshIntervalMinutes = (1...120).contains(interval) ? interval : 5
        notificationsEnabled = defaults.object(forKey: Self.notificationsKey) as? Bool ?? true
        if let store = SnapshotStore.shared() {
            service = ReminderService(store: store)
        } else {
            service = nil
            storeUnavailable = true
            Self.logger.error("App Group container unavailable; check entitlements")
        }
    }

    // MARK: Lifecycle

    func start() async {
        guard !started, let service else { return }
        started = true
        snapshot = await service.snapshot
        await refreshConnectionState()
        if isConnected {
            await sync(reason: "launch")
            restartRefreshLoop()
        } else {
            showConnect = true
        }
    }

    private func restartRefreshLoop() {
        refreshTask?.cancel()
        guard isConnected else { return }
        let interval = Duration.seconds(refreshIntervalMinutes * 60)
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.sync(reason: "timer")
            }
        }
    }

    private func refreshConnectionState() async {
        guard let service else { return }
        isConnected = await service.isConnected
        accountHint = await service.accountHint
        accountEmail = await service.accountEmail
    }

    // MARK: Cloud actions

    func sync(reason: String) async {
        guard let service, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            snapshot = try await service.sync()
            lastError = nil
            Self.logger.info("sync ok (\(reason, privacy: .public)) reminders=\(self.snapshot.reminders.count)")
            WidgetCenter.shared.reloadAllTimelines()
            await rescheduleNotifications()
        } catch {
            await handle(error)
        }
    }

    private(set) var signInInProgress = false

    /// Opens Samsung's sign-in page in the default browser; the callback lands in `handle(url:)`.
    func beginSignIn() async {
        guard let service else { return }
        do {
            let url = try await service.beginSignIn()
            signInInProgress = true
            lastError = nil
            NSWorkspace.shared.open(url)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func completeSignIn(callback: URL) async {
        guard let service else { return }
        defer { signInInProgress = false }
        do {
            try await service.completeSignIn(callback: callback)
            await refreshConnectionState()
            lastError = nil
            showConnect = false
            await sync(reason: "sign-in")
            restartRefreshLoop()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func connect(_ credential: CloudCredential) async -> Bool {
        guard let service else { return false }
        do {
            try await service.connect(credential)
            await refreshConnectionState()
            lastError = nil
            showConnect = false
            await sync(reason: "connect")
            restartRefreshLoop()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func disconnect() async {
        guard let service else { return }
        refreshTask?.cancel()
        do { try await service.disconnect() } catch { lastError = error.localizedDescription }
        snapshot = .empty
        selectedReminderID = nil
        await refreshConnectionState()
        await notifications.cancelAll()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func toggleCompleted(_ reminder: Reminder) {
        mutate { try await $0.setCompleted(reminder.id, !reminder.completed) }
    }

    func toggleFavorite(_ reminder: Reminder) {
        mutate { try await $0.setFavorite(reminder.id, !reminder.favorite) }
    }

    func create(_ draft: ReminderDraft) async -> Bool {
        await run { service in
            let created = try await service.create(draft)
            self.selectedReminderID = created.id
        }
    }

    func update(_ id: String, _ draft: ReminderDraft) async -> Bool {
        await run { _ = try await $0.update(id, draft) }
    }

    func createCategory(name: String, color: Int) async -> Bool {
        await run { let category = try await $0.createCategory(name: name, color: color); self.filter = .category(category.id) }
    }

    func updateCategory(_ id: String, name: String, color: Int) async -> Bool {
        await run { _ = try await $0.updateCategory(id, name: name, color: color) }
    }

    func deleteCategory(_ id: String) async -> Bool {
        await run { try await $0.deleteCategory(id, confirmID: id); if self.filter == .category(id) { self.filter = .all } }
    }

    /// Runs one cloud mutation, then refreshes snapshot, widget and notifications.
    @discardableResult
    private func run(_ operation: (ReminderService) async throws -> Void) async -> Bool {
        guard let service else { return false }
        do {
            try await operation(service)
            snapshot = await service.snapshot
            lastError = nil
            WidgetCenter.shared.reloadAllTimelines()
            await rescheduleNotifications()
            return true
        } catch {
            await handle(error)
            return false
        }
    }

    func delete(_ reminder: Reminder) {
        guard let service else { return }
        Task {
            do {
                try await service.delete(reminder.id, confirmID: reminder.id)
                snapshot = await service.snapshot
                if selectedReminderID == reminder.id { selectedReminderID = nil }
                WidgetCenter.shared.reloadAllTimelines()
                await rescheduleNotifications()
            } catch {
                await handle(error)
            }
        }
    }

    private func mutate(_ operation: @escaping @Sendable (ReminderService) async throws -> Reminder) {
        guard let service else { return }
        Task {
            do {
                _ = try await operation(service)
                snapshot = await service.snapshot
                lastError = nil
                WidgetCenter.shared.reloadAllTimelines()
                await rescheduleNotifications()
            } catch {
                await handle(error)
            }
        }
    }

    private func handle(_ error: Error) async {
        lastError = error.localizedDescription
        Self.logger.error("\(error.localizedDescription, privacy: .public)")
        if case CloudError.unauthorized = error {
            await refreshConnectionState()
            refreshTask?.cancel()
            showConnect = true
        }
    }

    private func rescheduleNotifications() async {
        guard notificationsEnabled else { await notifications.cancelAll(); return }
        await notifications.schedule(for: snapshot.pending())
    }

    // MARK: Derived

    var visibleReminders: [Reminder] {
        let calendar = Calendar.current
        let now = Date()
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        return snapshot.reminders.filter { reminder in
            let passesFilter: Bool
            switch filter {
            case .all: passesFilter = !reminder.completed
            case .today: passesFilter = !reminder.completed && reminder.dueAt.map(calendar.isDateInToday) == true
            case .upcoming: passesFilter = !reminder.completed && (reminder.dueAt ?? .distantPast) > now
            case .favorites: passesFilter = reminder.favorite && !reminder.completed
            case .completed: passesFilter = reminder.completed
            case .category(let id): passesFilter = reminder.categoryID == id && !reminder.completed
            }
            guard passesFilter else { return false }
            guard !needle.isEmpty else { return true }
            return reminder.title.localizedCaseInsensitiveContains(needle)
                || reminder.text.localizedCaseInsensitiveContains(needle)
        }
    }

    var selectedReminder: Reminder? {
        guard let selectedReminderID else { return nil }
        return snapshot.reminders.first { $0.id == selectedReminderID }
    }

    func categoryName(_ id: String) -> String {
        id == defaultCategoryID ? "My reminders" : snapshot.categories.first { $0.id == id }?.name ?? "Unknown list"
    }

    var menuBarSymbol: String {
        if !isConnected { return "bell.slash" }
        return snapshot.pending().contains { ($0.dueAt ?? .distantFuture) < Date() } ? "bell.badge" : "bell"
    }

    func handle(url: URL) {
        if SamsungAccountAuth.isCallback(url) {
            NSApp.activate(ignoringOtherApps: true)
            Task { await completeSignIn(callback: url) }
            return
        }
        // samsungreminder://reminder/<id> from the widget.
        guard url.scheme == "samsungreminder", url.host == "reminder" else { return }
        let id = url.lastPathComponent
        if snapshot.reminders.contains(where: { $0.id == id }) { selectedReminderID = id }
    }
}
