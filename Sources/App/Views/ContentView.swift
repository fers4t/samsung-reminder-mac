import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
        } content: {
            ReminderList()
                .navigationSplitViewColumnWidth(min: 320, ideal: 380)
        } detail: {
            if let reminder = model.selectedReminder {
                ReminderDetail(reminder: reminder)
            } else {
                ContentUnavailableView("Select a reminder", systemImage: "checklist")
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search reminders")
        .toolbar {
            ToolbarItemGroup {
                if model.isSyncing { ProgressView().controlSize(.small) }
                Button { Task { await model.sync(reason: "toolbar") } } label: { Label("Sync", systemImage: "arrow.clockwise") }
                    .disabled(!model.isConnected || model.isSyncing)
                Button { model.showNewReminder = true } label: { Label("New Reminder", systemImage: "plus") }
                    .disabled(!model.isConnected)
            }
        }
        .sheet(isPresented: $model.showConnect) { ConnectSheet() }
        .sheet(isPresented: $model.showNewReminder) { NewReminderSheet() }
        .overlay(alignment: .bottom) { StatusBanner() }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.filter) {
            Section {
                Label("All", systemImage: "tray.full").tag(AppModel.Filter.all)
                Label("Today", systemImage: "calendar").tag(AppModel.Filter.today)
                Label("Upcoming", systemImage: "clock").tag(AppModel.Filter.upcoming)
                Label("Favorites", systemImage: "star").tag(AppModel.Filter.favorites)
                Label("Completed", systemImage: "checkmark.circle").tag(AppModel.Filter.completed)
            }
            Section("Lists") {
                Label("My reminders", systemImage: "list.bullet").tag(AppModel.Filter.category(defaultCategoryID))
                ForEach(model.snapshot.categories) { category in
                    Label { Text(category.name) } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(ListColor.color(category.color))
                    }
                    .tag(AppModel.Filter.category(category.id))
                    .contextMenu {
                        Button("Edit List…") { editing = category }
                        Button("Delete List…", role: .destructive) { deleting = category }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        .safeAreaInset(edge: .bottom) {
            Button { creating = true } label: { Label("New List", systemImage: "plus.circle") }
                .buttonStyle(.plain).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!model.isConnected)
        }
        .sheet(isPresented: $creating) { ListSheet(existing: nil) }
        .sheet(item: $editing) { ListSheet(existing: $0) }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete List", role: .destructive) {
                if let deleting { Task { await model.deleteCategory(deleting.id) } }
                deleting = nil
            }
        } message: {
            Text("Its reminders move to My reminders. This happens in Samsung Cloud on every device.")
        }
    }

    @State private var creating = false
    @State private var editing: ReminderCategory?
    @State private var deleting: ReminderCategory?
}

struct ReminderList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let reminders = model.visibleReminders
        Group {
            if !model.isConnected {
                ContentUnavailableView {
                    Label("Not connected", systemImage: "bell.slash")
                } description: {
                    Text("Connect your Samsung Cloud credential to load reminders.")
                } actions: {
                    Button("Connect…") { model.showConnect = true }.buttonStyle(.borderedProminent)
                }
            } else if reminders.isEmpty {
                ContentUnavailableView("Nothing here", systemImage: "checkmark.circle", description: Text("No reminders match this view."))
            } else {
                List(reminders, selection: $model.selectedReminderID) { reminder in
                    ReminderRow(reminder: reminder)
                        .tag(reminder.id)
                        .contextMenu {
                            Button(reminder.completed ? "Mark Incomplete" : "Mark Complete") { model.toggleCompleted(reminder) }
                            Button(reminder.favorite ? "Remove Favorite" : "Add to Favorites") { model.toggleFavorite(reminder) }
                            Divider()
                            Button("Delete…", role: .destructive) { pendingDelete = reminder }
                        }
                }
            }
        }
        .navigationTitle(title)
        .confirmationDialog("Delete “\(pendingDelete?.title ?? "")”?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let pendingDelete { model.delete(pendingDelete) }
                pendingDelete = nil
            }
        } message: {
            Text("This removes the reminder from Samsung Cloud on every device.")
        }
    }

    @State private var pendingDelete: Reminder?

    private var title: String {
        switch model.filter {
        case .all: "All"
        case .today: "Today"
        case .upcoming: "Upcoming"
        case .favorites: "Favorites"
        case .completed: "Completed"
        case .category(let id): model.categoryName(id)
        }
    }
}

struct ReminderRow: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { model.toggleCompleted(reminder) } label: {
                Image(systemName: reminder.completed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(reminder.completed ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reminder.completed ? "Mark incomplete" : "Mark complete")

            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title.isEmpty ? "Untitled" : reminder.title)
                    .strikethrough(reminder.completed)
                    .foregroundStyle(reminder.completed ? .secondary : .primary)
                    .lineLimit(2)
                if !reminder.text.isEmpty, reminder.text != reminder.title {
                    Text(reminder.text).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let due = reminder.dueAt { DueLabel(date: due, allDay: reminder.allDay, overdue: !reminder.completed && due < Date()) }
                    if reminder.repeats { Image(systemName: "repeat").font(.caption2).foregroundStyle(.secondary) }
                    if reminder.hasLocation { Image(systemName: "mappin").font(.caption2).foregroundStyle(.secondary) }
                    if !reminder.checklist.isEmpty {
                        Text("\(reminder.checklist.filter(\.done).count)/\(reminder.checklist.count)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            Button { model.toggleFavorite(reminder) } label: {
                Image(systemName: reminder.favorite ? "star.fill" : "star")
                    .foregroundStyle(reminder.favorite ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reminder.favorite ? "Remove favorite" : "Add favorite")
        }
        .padding(.vertical, 4)
    }
}

struct DueLabel: View {
    let date: Date
    let allDay: Bool
    let overdue: Bool

    var body: some View {
        Text(date, format: allDay ? .dateTime.day().month().year() : .dateTime.day().month().hour().minute())
            .font(.caption)
            .foregroundStyle(overdue ? .red : .secondary)
    }
}

struct ReminderDetail: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder
    @State private var draft: ReminderDraft
    @State private var busy = false

    init(reminder: Reminder) {
        self.reminder = reminder
        _draft = State(initialValue: ReminderDraft(reminder: reminder))
    }

    private var dirty: Bool { draft != ReminderDraft(reminder: reminder) }

    var body: some View {
        VStack(spacing: 0) {
            ReminderEditor(draft: $draft)
            VStack(alignment: .leading, spacing: 6) {
                if reminder.attachmentCount > 0 {
                    Label("\(reminder.attachmentCount) photo attachment(s) — viewable on the phone only", systemImage: "photo")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let url = reminder.url.flatMap(URL.init(string:)), ["http", "https"].contains(url.scheme ?? "") {
                    Link(reminder.webTitle ?? url.absoluteString, destination: url).font(.caption).lineLimit(1)
                }
                HStack {
                    Text("Modified \(reminder.modifiedAt, format: .dateTime)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(reminder.completed ? "Mark Incomplete" : "Mark Complete") { model.toggleCompleted(reminder) }
                    Button("Revert") { draft = ReminderDraft(reminder: reminder) }.disabled(!dirty)
                    Button("Save") { save() }
                        .keyboardShortcut("s")
                        .buttonStyle(.borderedProminent)
                        .disabled(!dirty || busy || draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(12)
        }
        // A background sync may replace the reminder; keep local edits unless the user has none.
        .onChange(of: reminder) { _, updated in if !dirty { draft = ReminderDraft(reminder: updated) } }
        .onChange(of: draft.checklist.map(\.done)) { old, new in
            // Checking an item off is the everyday action; save it right away when nothing else is pending.
            guard old.count == new.count, old != new else { return }
            var quick = ReminderDraft(reminder: reminder)
            guard quick.checklist.count == new.count else { return }
            for (index, done) in new.enumerated() { quick.checklist[index].done = done }
            if draft == quick { save() }
        }
    }

    private func save() {
        busy = true
        Task {
            _ = await model.update(reminder.id, draft)
            busy = false
        }
    }
}

struct StatusBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let error = model.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding()
                .transition(.move(edge: .bottom))
        } else if model.snapshot.truncated {
            Label("Showing the first 500 reminders; Samsung's list API returns one page.", systemImage: "info.circle")
                .font(.callout).padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding()
        }
    }
}
