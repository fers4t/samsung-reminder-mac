import SwiftUI
import WidgetKit

/// Read-only view of the app's snapshot. The extension never touches the
/// network or the Keychain; the app reloads the timeline after every sync.
struct ReminderEntry: TimelineEntry {
    let date: Date
    let snapshot: ReminderSnapshot
    let configured: Bool
}

struct ReminderProvider: TimelineProvider {
    private func load() -> ReminderEntry {
        guard let store = SnapshotStore.shared() else {
            return ReminderEntry(date: Date(), snapshot: .empty, configured: false)
        }
        let snapshot = (try? store.load()) ?? .empty
        return ReminderEntry(date: Date(), snapshot: snapshot, configured: snapshot.syncedAt != .distantPast)
    }

    func placeholder(in context: Context) -> ReminderEntry {
        ReminderEntry(date: Date(), snapshot: .empty, configured: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (ReminderEntry) -> Void) {
        completion(load())
    }

    /// Re-render at each upcoming due time so overdue colouring flips without the app.
    func getTimeline(in context: Context, completion: @escaping (Timeline<ReminderEntry>) -> Void) {
        let entry = load()
        let now = Date()
        var dates = entry.snapshot.pending(limit: 20).compactMap(\.dueAt).filter { $0 > now }.prefix(5).map { $0.addingTimeInterval(1) }
        dates.insert(now, at: 0)
        let entries = dates.map { ReminderEntry(date: $0, snapshot: entry.snapshot, configured: entry.configured) }
        let refresh = Calendar.current.date(byAdding: .minute, value: 30, to: now) ?? now.addingTimeInterval(1800)
        completion(Timeline(entries: entries, policy: .after(refresh)))
    }
}

struct ReminderWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ReminderEntry

    private var rowLimit: Int {
        switch family {
        case .systemSmall: 3
        case .systemMedium: 4
        default: 10
        }
    }

    var body: some View {
        let pending = entry.snapshot.pending(limit: rowLimit)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "bell.fill").foregroundStyle(.tint)
                Text("Reminders").font(.headline)
                Spacer()
                if entry.configured {
                    Text("\(entry.snapshot.pending().count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if !entry.configured {
                Text("Open Samsung Reminder to connect.").font(.caption).foregroundStyle(.secondary)
            } else if pending.isEmpty {
                Text("All done").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(pending) { reminder in
                    Link(destination: URL(string: "samsungreminder://reminder/\(reminder.id)")!) {
                        HStack(spacing: 6) {
                            Image(systemName: "circle").font(.caption2).foregroundStyle(.secondary)
                            Text(reminder.title.isEmpty ? "Untitled" : reminder.title).font(.callout).lineLimit(1)
                            Spacer(minLength: 0)
                            if family != .systemSmall, let due = reminder.dueAt {
                                Text(due, format: Calendar.current.isDateInToday(due) ? .dateTime.hour().minute() : .dateTime.day().month())
                                    .font(.caption2)
                                    .foregroundStyle(due < entry.date ? .red : .secondary)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

@main
struct ReminderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SamsungReminderWidget", provider: ReminderProvider()) { entry in
            ReminderWidgetView(entry: entry)
        }
        .configurationDisplayName("Samsung Reminders")
        .description("Your pending Samsung reminders, synced by the app.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
