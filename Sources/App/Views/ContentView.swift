import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
        } content: {
            ReminderList()
                .navigationSplitViewColumnWidth(min: 320, ideal: 400)
        } detail: {
            Group {
                if let reminder = model.selectedReminder {
                    ReminderDetail(reminder: reminder).id(reminder.id)
                } else {
                    ContentUnavailableView("Select a reminder", systemImage: "checklist", description: Text("Or press ⌘N to add one."))
                }
            }
            .navigationSplitViewColumnWidth(min: 380, ideal: 480)
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search")
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

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var creating = false
    @State private var editing: ReminderCategory?
    @State private var deleting: ReminderCategory?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.filter) {
            Section {
                SmartListRow(title: "Today", symbol: "calendar", color: .blue, count: model.count(for: .today)).tag(AppModel.Filter.today)
                SmartListRow(title: "Upcoming", symbol: "clock", color: .orange, count: model.count(for: .upcoming)).tag(AppModel.Filter.upcoming)
                SmartListRow(title: "All", symbol: "tray.full", color: .gray, count: model.count(for: .all)).tag(AppModel.Filter.all)
                SmartListRow(title: "Important", symbol: "star", color: .yellow, count: model.count(for: .favorites)).tag(AppModel.Filter.favorites)
                SmartListRow(title: "Completed", symbol: "checkmark", color: .green, count: nil).tag(AppModel.Filter.completed)
            }
            Section("My Lists") {
                ListRow(name: "My reminders", color: .gray, count: model.count(for: .category(defaultCategoryID)))
                    .tag(AppModel.Filter.category(defaultCategoryID))
                ForEach(model.snapshot.categories) { category in
                    ListRow(name: category.name, color: ListColor.color(category.color), count: model.count(for: .category(category.id)))
                        .tag(AppModel.Filter.category(category.id))
                        .contextMenu {
                            Button("Edit List…") { editing = category }
                            Button("Delete List…", role: .destructive) { deleting = category }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        .safeAreaInset(edge: .bottom) {
            Button { creating = true } label: { Label("Add List", systemImage: "plus.circle") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
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
}

struct SmartListRow: View {
    let title: String, symbol: String, color: Color, count: Int?
    var body: some View {
        HStack {
            Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(color.gradient, in: RoundedRectangle(cornerRadius: 6))
            Text(title)
            Spacer()
            if let count, count > 0 { Text("\(count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
        }
    }
}

struct ListRow: View {
    let name: String, color: Color, count: Int
    var body: some View {
        HStack {
            Circle().fill(color.gradient).frame(width: 10, height: 10).padding(.horizontal, 6)
            Text(name).lineLimit(1)
            Spacer()
            if count > 0 { Text("\(count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - List

struct ReminderList: View {
    @Environment(AppModel.self) private var model
    @State private var pendingDelete: Reminder?

    var body: some View {
        @Bindable var model = model
        let groups = model.groupedReminders
        Group {
            if !model.isConnected {
                ContentUnavailableView {
                    Label("Not connected", systemImage: "bell.slash")
                } description: {
                    Text("Sign in with your Samsung Account to load reminders.")
                } actions: {
                    Button("Connect…") { model.showConnect = true }.buttonStyle(.borderedProminent)
                }
            } else {
                List(selection: $model.selectedReminderID) {
                    if groups.isEmpty {
                        ContentUnavailableView("All clear", systemImage: "checkmark.circle", description: Text("Nothing in this view."))
                            .listRowSeparator(.hidden)
                    }
                    ForEach(groups, id: \.title) { group in
                        Section {
                            ForEach(group.reminders) { reminder in
                                ReminderRow(reminder: reminder)
                                    .tag(reminder.id)
                                    .listRowSeparator(.hidden)
                                    .contextMenu {
                                        Button(reminder.completed ? "Mark Incomplete" : "Mark Complete") { model.toggleCompleted(reminder) }
                                        Button(reminder.favorite ? "Unmark Important" : "Mark Important") { model.toggleFavorite(reminder) }
                                        Divider()
                                        Button("Delete…", role: .destructive) { pendingDelete = reminder }
                                    }
                            }
                        } header: {
                            if let title = group.title {
                                Text(title).font(.caption.weight(.semibold)).foregroundStyle(group.tint).padding(.vertical, 2)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .safeAreaInset(edge: .bottom) { QuickAddBar() }
            }
        }
        .navigationTitle(model.filterTitle)
        .navigationSubtitle(model.isConnected ? "\(model.count(for: model.filter)) open" : "")
        .confirmationDialog("Delete “\(pendingDelete?.title ?? "")”?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let pendingDelete { model.delete(pendingDelete) }
                pendingDelete = nil
            }
        } message: {
            Text("This removes the reminder from Samsung Cloud on every device.")
        }
    }
}

/// Capture in one line: type naturally ("rapor yarın 15:00 #iş !"), see what was understood as chips,
/// press Return. The field clears at once and keeps focus so several thoughts can be dumped in a row.
struct QuickAddBar: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var ignored: Set<QuickEntry.ChipKind> = []
    @FocusState private var focused: Bool

    private var entry: QuickEntry {
        QuickEntryParser.parse(text, lists: model.snapshot.categories.map { .init(id: $0.id, name: $0.name) }, ignoring: ignored)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor).font(.title3)
                TextField("", text: $text, prompt: Text(model.quickAddHint))
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(add)
                    .onExitCommand { text = ""; ignored = [] }
                if model.pendingAdds > 0 { ProgressView().controlSize(.small) }
            }
            if !text.isEmpty {
                HStack(spacing: 6) {
                    ForEach(entry.chips, id: \.kind) { chip in
                        EntryChip(chip: chip) { ignored.insert(chip.kind) }
                    }
                    if entry.chips.isEmpty {
                        Text("Try “yarın 15:00”, “every monday”, “#list”, “!”").font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text("↩ add").font(.caption).foregroundStyle(.tertiary)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .animation(.snappy(duration: 0.15), value: entry.chips)
        .onChange(of: text) { _, new in if new.isEmpty { ignored = [] } }
        .onAppear { focused = true }
    }

    private func add() {
        let parsed = entry
        guard !parsed.title.isEmpty else { return }
        var draft = ReminderDraft(entry: parsed)
        if parsed.categoryID == nil, case .category(let id) = model.filter { draft.categoryID = id }
        if parsed.date == nil {
            if model.filter == .today { draft.schedule = .allDay(Date()) }
            if model.filter == .upcoming, let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) { draft.schedule = .allDay(tomorrow) }
        }
        if model.filter == .favorites { draft.favorite = true }
        let typed = text
        text = ""
        ignored = []
        focused = true
        Task {
            // Optimistic: the field is already clear; bring the text back only if the cloud said no.
            if !(await model.quickAdd(draft)) { text = typed }
        }
    }
}

struct EntryChip: View {
    let chip: QuickEntry.Chip
    let remove: () -> Void

    private var symbol: String {
        switch chip.kind {
        case .date: "calendar"; case .time: "clock"; case .repeatRule: "repeat"; case .list: "list.bullet"; case .important: "star.fill"
        }
    }
    private var tint: Color {
        switch chip.kind {
        case .date: .red; case .time: .blue; case .repeatRule: .purple; case .list: .gray; case .important: .yellow
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.caption2)
            Text(chip.label).font(.caption)
            Button(action: remove) { Image(systemName: "xmark").font(.caption2) }
                .buttonStyle(.plain).accessibilityLabel("Ignore \(chip.label)")
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(tint.opacity(0.18), in: Capsule())
        .foregroundStyle(tint)
    }
}

struct ReminderRow: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CheckCircle(done: reminder.completed) { model.toggleCompleted(reminder) }
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.title.isEmpty ? "Untitled" : reminder.title)
                    .font(.body.weight(.medium))
                    .strikethrough(reminder.completed)
                    .foregroundStyle(reminder.completed ? .secondary : .primary)
                    .lineLimit(2)
                if !reminder.text.isEmpty, reminder.text != reminder.title {
                    Text(reminder.text).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    if let due = reminder.dueAt {
                        DueChip(date: due, allDay: reminder.allDay, overdue: !reminder.completed && due < Date(), repeats: reminder.repeats)
                    }
                    if !reminder.checklist.isEmpty {
                        Label("\(reminder.checklist.filter(\.done).count)/\(reminder.checklist.count)", systemImage: "checklist")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if reminder.hasLocation { Image(systemName: "location").font(.caption).foregroundStyle(.secondary) }
                    if reminder.attachmentCount > 0 { Image(systemName: "photo").font(.caption).foregroundStyle(.secondary) }
                    if model.filter != .category(reminder.categoryID), reminder.categoryID != defaultCategoryID,
                       let category = model.snapshot.categories.first(where: { $0.id == reminder.categoryID }) {
                        HStack(spacing: 4) {
                            Circle().fill(ListColor.color(category.color)).frame(width: 7, height: 7)
                            Text(category.name).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Button { model.toggleFavorite(reminder) } label: {
                Image(systemName: reminder.favorite ? "star.fill" : "star")
                    .foregroundStyle(reminder.favorite ? Color.yellow : Color.secondary.opacity(0.35))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reminder.favorite ? "Unmark important" : "Mark important")
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
    }
}

/// Round checkbox with a short fill animation, like Reminders.
struct CheckCircle: View {
    let done: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(done ? Color.accentColor : Color.secondary.opacity(0.6), lineWidth: 1.5)
                Circle().fill(Color.accentColor).padding(3)
                    .scaleEffect(done ? 1 : 0.01)
                    .opacity(done ? 1 : 0)
                    .animation(.snappy(duration: 0.2), value: done)
            }
            .frame(width: 20, height: 20)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(done ? "Mark incomplete" : "Mark complete")
    }
}

struct DueChip: View {
    let date: Date
    let allDay: Bool
    let overdue: Bool
    var repeats = false

    private var text: String {
        let calendar = Calendar.current
        let day: String
        if calendar.isDateInToday(date) { day = "Today" }
        else if calendar.isDateInTomorrow(date) { day = "Tomorrow" }
        else if calendar.isDateInYesterday(date) { day = "Yesterday" }
        else if calendar.isDate(date, equalTo: Date(), toGranularity: .year) { day = date.formatted(.dateTime.day().month(.abbreviated)) }
        else { day = date.formatted(.dateTime.day().month(.abbreviated).year()) }
        return allDay ? day : "\(day), \(date.formatted(.dateTime.hour().minute()))"
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: repeats ? "repeat" : "calendar")
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(overdue ? Color.red : Calendar.current.isDateInToday(date) ? Color.accentColor : Color.secondary)
    }
}

// MARK: - Detail

struct ReminderDetail: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder
    @State private var draft: ReminderDraft
    @State private var saveTask: Task<Void, Never>?
    @State private var saving = false
    @State private var lastSaved: Date?

    init(reminder: Reminder) {
        self.reminder = reminder
        _draft = State(initialValue: ReminderDraft(reminder: reminder))
    }

    private var dirty: Bool { draft != ReminderDraft(reminder: reminder) }

    var body: some View {
        ReminderEditor(draft: $draft, reminder: reminder)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Group {
                        if saving { Label("Saving…", systemImage: "arrow.triangle.2.circlepath") }
                        else if dirty { Label("Unsaved changes", systemImage: "pencil") }
                        else if let lastSaved { Label("Saved \(lastSaved, style: .relative) ago", systemImage: "checkmark.icloud") }
                        else { Text("Modified \(reminder.modifiedAt, format: .dateTime)") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(reminder.completed ? "Mark Incomplete" : "Complete") { model.toggleCompleted(reminder) }
                    Button("Save Now") { flush() }.keyboardShortcut("s").disabled(!dirty || saving)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
            }
            // Autosave a second after the last edit; the actor serialises the uploads.
            .onChange(of: draft) { _, _ in
                saveTask?.cancel()
                guard dirty, !draft.title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                saveTask = Task {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    await save()
                }
            }
            // A background sync may replace the reminder; adopt it only when nothing is pending.
            .onChange(of: reminder) { _, updated in if !dirty { draft = ReminderDraft(reminder: updated) } }
            .onDisappear { flush() }
    }

    private func flush() {
        saveTask?.cancel()
        guard dirty else { return }
        Task { await save() }
    }

    private func save() async {
        saving = true
        if await model.update(reminder.id, draft) { lastSaved = Date() }
        saving = false
    }
}

struct StatusBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let undo = model.undo {
            HStack(spacing: 12) {
                Label("Completed “\(undo.title)”", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Undo") { model.performUndo() }.keyboardShortcut("z", modifiers: .command)
            }
            .font(.callout).padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding()
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let error = model.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding()
                .transition(.move(edge: .bottom))
        } else if model.snapshot.truncated {
            Label("Showing the first 500 reminders; Samsung's list API returns one page.", systemImage: "info.circle")
                .font(.callout).padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding()
        }
    }
}
