import SwiftUI

/// Manual credential entry. See README for how the token is obtained; macOS has
/// no Samsung Browser, so the private credential API the Windows client uses is unavailable.
struct ConnectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var accessToken = ""
    @State private var userId = ""
    @State private var deviceId = ""
    @State private var email = ""
    @State private var busy = false
    @State private var showManual = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect Samsung Cloud").font(.title2.weight(.semibold))
            Text("Sign in on Samsung's own account page in your browser. This app never sees your password or verification code; it receives only a session token, which is kept in your macOS Keychain and sent solely to Samsung's servers.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button { Task { await model.beginSignIn() } } label: {
                    Label(model.signInInProgress ? "Waiting for the browser…" : "Sign in with Samsung Account", systemImage: "person.crop.circle.badge.checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
                if model.signInInProgress { ProgressView().controlSize(.small) }
            }
            if model.signInInProgress {
                Text("Finish signing in. Samsung will hand you back to this app automatically. If the browser asks which app should open the link, choose Samsung Reminder.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.lastError {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            DisclosureGroup("Advanced: paste an existing credential", isExpanded: $showManual) {
                Form {
                    SecureField("Access token", text: $accessToken)
                    TextField("User ID", text: $userId)
                    TextField("Device ID", text: $deviceId)
                    TextField("Account email (optional, display only)", text: $email)
                }
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                HStack {
                    Button("Paste credential JSON") { pasteJSON() }
                    Spacer()
                    Button("Connect with pasted credential") { connect() }
                        .disabled(busy || accessToken.isEmpty || userId.isEmpty || deviceId.isEmpty)
                }
                .padding(.top, 6)
            }
            .font(.callout)
            Link("How this works",
                 destination: URL(string: "https://github.com/fers4t/samsung-reminder-mac#how-it-gets-your-data")!)
                .font(.callout)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 540)
        .disabled(busy)
    }

    private func connect() {
        busy = true
        Task {
            _ = await model.connect(CloudCredential(accessToken: accessToken, userId: userId, deviceId: deviceId,
                                                    accountEmail: email.isEmpty ? nil : email))
            busy = false
            // Clear the token from view state regardless of outcome.
            accessToken = ""
        }
    }

    /// Accepts `{"accessToken":"…","userId":"…","deviceId":"…"}` — the same shape
    /// the reference Windows client stores.
    private func pasteJSON() {
        guard let string = NSPasteboard.general.string(forType: .string),
              string.utf8.count < 16_384,
              let data = string.data(using: .utf8),
              let credential = try? JSONDecoder().decode(CloudCredential.self, from: data) else { return }
        accessToken = credential.accessToken
        userId = credential.userId
        deviceId = credential.deviceId
        email = credential.accountEmail ?? ""
    }
}

struct NewReminderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var hasDue = false
    @State private var dueAt = Calendar.current.nextDate(after: Date(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? Date()
    @State private var categoryID = defaultCategoryID
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Reminder").font(.title2.weight(.semibold))
            Form {
                TextField("Title", text: $title)
                TextField("Notes", text: $text, axis: .vertical).lineLimit(3...6)
                Picker("List", selection: $categoryID) {
                    Text("My reminders").tag(defaultCategoryID)
                    ForEach(model.snapshot.categories) { Text($0.name).tag($0.id) }
                }
                Toggle("Remind me at", isOn: $hasDue)
                if hasDue {
                    DatePicker("Time", selection: $dueAt, displayedComponents: [.date, .hourAndMinute])
                }
            }
            .textFieldStyle(.roundedBorder)
            if let error = model.lastError { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .disabled(busy)
        .onAppear {
            if case .category(let id) = model.filter { categoryID = id }
        }
    }

    private func add() {
        busy = true
        Task {
            let ok = await model.create(.init(title: title, text: text, dueAt: hasDue ? dueAt : nil, categoryID: categoryID))
            busy = false
            if ok { dismiss() }
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Account") {
                if model.isConnected {
                    LabeledContent("Connected as", value: model.accountEmail ?? model.accountHint ?? "Samsung account")
                    Button("Disconnect Samsung account", role: .destructive) { Task { await model.disconnect() } }
                    Text("Removes the credential from the Keychain and the local cache. Reminders in Samsung Cloud are untouched.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Connect…") { model.showConnect = true }
                }
            }
            Section("Sync") {
                Picker("Refresh every", selection: $model.refreshIntervalMinutes) {
                    ForEach([1, 2, 5, 10, 15, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
                }
                LabeledContent("Last sync") {
                    if model.snapshot.syncedAt == .distantPast { Text("Never") }
                    else { Text(model.snapshot.syncedAt, format: .relative(presentation: .named)) }
                }
            }
            Section("Notifications") {
                Toggle("Notify me when a reminder is due", isOn: $model.notificationsEnabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding(.vertical, 8)
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Upcoming").font(.headline)
                Spacer()
                if model.isSyncing { ProgressView().controlSize(.mini) }
                Button { Task { await model.sync(reason: "menubar") } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(!model.isConnected)
            }
            let pending = model.snapshot.pending(limit: 8)
            if !model.isConnected {
                Text("Not connected").foregroundStyle(.secondary)
            } else if pending.isEmpty {
                Text("All done 🎉").foregroundStyle(.secondary)
            } else {
                ForEach(pending) { reminder in
                    Button {
                        model.toggleCompleted(reminder)
                    } label: {
                        HStack {
                            Image(systemName: "circle")
                            Text(reminder.title).lineLimit(1)
                            Spacer()
                            if let due = reminder.dueAt {
                                Text(due, format: Calendar.current.isDateInToday(due) ? .dateTime.hour().minute() : .dateTime.day().month())
                                    .foregroundStyle(due < Date() ? .red : .secondary).font(.caption)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            HStack {
                Button("Open Samsung Reminder") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 320)
    }
}
