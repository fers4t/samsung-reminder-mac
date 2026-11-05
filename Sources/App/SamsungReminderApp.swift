import SwiftUI

@main
struct SamsungReminderApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Samsung Reminder", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 940, minHeight: 520)
                .task { await model.start() }
                .onOpenURL { model.handle(url: $0) }
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Reminder…") { model.showNewReminder = true }
                    .keyboardShortcut("n")
                Button("Sync Now") { Task { await model.sync(reason: "manual") } }
                    .keyboardShortcut("r")
                    .disabled(!model.isConnected)
            }
        }

        MenuBarExtra("Samsung Reminder", systemImage: model.menuBarSymbol) {
            MenuBarContent().environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(model)
        }
    }
}
