import MapKit
import SwiftUI

/// One editor for creating and editing: big title, notes, checklist, then attribute rows.
/// The caller owns the draft and decides when to save.
struct ReminderEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: ReminderDraft
    var reminder: Reminder? = nil
    @State private var newItem = ""
    @State private var showLocationPicker = false
    @FocusState private var newItemFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("", text: $draft.title, prompt: Text("Title"), axis: .vertical)
                        .textFieldStyle(.plain).font(.title.weight(.semibold)).lineLimit(1...3)
                    TextField("", text: $draft.text, prompt: Text("Notes"), axis: .vertical)
                        .textFieldStyle(.plain).foregroundStyle(.secondary).lineLimit(1...10)
                }

                checklistCard

                AttributeCard {
                    scheduleRows
                }
                AttributeCard {
                    placeRows
                }
                AttributeCard {
                    AttributeRow(symbol: "list.bullet", tint: .gray, title: "List") {
                        Picker("", selection: $draft.categoryID) {
                            Text("My reminders").tag(defaultCategoryID)
                            ForEach(model.snapshot.categories) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    AttributeRow(symbol: "star", tint: .yellow, title: "Important") {
                        Toggle("", isOn: $draft.favorite).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }

                if let reminder {
                    VStack(alignment: .leading, spacing: 4) {
                        if reminder.attachmentCount > 0 {
                            Label("\(reminder.attachmentCount) photo attachment(s), viewable on the phone only", systemImage: "photo")
                        }
                        if let url = reminder.url.flatMap(URL.init(string:)), ["http", "https"].contains(url.scheme ?? "") {
                            Link(destination: url) { Label(reminder.webTitle ?? url.absoluteString, systemImage: "link").lineLimit(1) }
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showLocationPicker) {
            LocationPicker { place in
                draft.location = ReminderLocation(latitude: place.latitude, longitude: place.longitude, address: place.address,
                                                  placeName: place.name, transition: draft.location?.transition ?? .arrive)
            }
        }
    }

    // MARK: Checklist

    private var checklistCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach($draft.checklist.indices, id: \.self) { index in
                HStack(spacing: 10) {
                    CheckCircle(done: draft.checklist[index].done) { draft.checklist[index].done.toggle() }
                    TextField("", text: $draft.checklist[index].text, prompt: Text("Item"))
                        .textFieldStyle(.plain)
                        .strikethrough(draft.checklist[index].done)
                        .foregroundStyle(draft.checklist[index].done ? .secondary : .primary)
                    Button { draft.checklist.remove(at: index) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.quaternary)
                        .accessibilityLabel("Remove item")
                }
                .padding(.vertical, 6)
            }
            HStack(spacing: 10) {
                Image(systemName: "plus.circle").foregroundStyle(.secondary)
                TextField("", text: $newItem, prompt: Text(draft.checklist.isEmpty ? "Add a checklist item" : "Add item"))
                    .textFieldStyle(.plain)
                    .focused($newItemFocused)
                    .onSubmit(addItem)
            }
            .padding(.vertical, 6)
        }
    }

    private func addItem() {
        let text = newItem.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, draft.checklist.count < 200 else { return }
        draft.checklist.append(.init(text: text, done: false))
        newItem = ""
        newItemFocused = true
    }

    // MARK: Schedule

    private var scheduleKind: Binding<Int> {
        Binding {
            switch draft.schedule { case .none: 0; case .timed: 1; case .allDay: 2 }
        } set: { kind in
            let date = draft.schedule.date ?? Self.nextHour()
            switch kind {
            case 1: draft.schedule = .timed(date)
            case 2: draft.schedule = .allDay(date)
            default: draft.schedule = .none; draft.repeatRule = nil; draft.earlyAlert = nil
            }
        }
    }

    private var scheduleDate: Binding<Date> {
        Binding { draft.schedule.date ?? Self.nextHour() } set: { date in
            if case .allDay = draft.schedule { draft.schedule = .allDay(date) } else { draft.schedule = .timed(date) }
        }
    }

    static func nextHour() -> Date {
        Calendar.current.nextDate(after: Date(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? Date()
    }

    @ViewBuilder private var scheduleRows: some View {
        AttributeRow(symbol: "calendar", tint: .red, title: "Date") {
            Picker("", selection: scheduleKind) {
                Text("None").tag(0)
                Text("Time").tag(1)
                Text("Day").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        if case .timed = draft.schedule {
            AttributeRow(symbol: "clock", tint: .blue, title: "When") {
                DatePicker("", selection: scheduleDate, displayedComponents: [.date, .hourAndMinute]).labelsHidden()
            }
        } else if case .allDay = draft.schedule {
            AttributeRow(symbol: "sun.max", tint: .orange, title: "Day") {
                DatePicker("", selection: scheduleDate, displayedComponents: [.date]).labelsHidden()
            }
        }
        if draft.schedule.date != nil {
            AttributeRow(symbol: "repeat", tint: .purple, title: "Repeat") {
                RepeatPicker(rule: $draft.repeatRule, allDay: { if case .allDay = draft.schedule { true } else { false } }())
            }
            AttributeRow(symbol: "bell.badge", tint: .teal, title: "Early reminder") {
                EarlyAlertPicker(alert: $draft.earlyAlert)
            }
            AttributeRow(symbol: "speaker.wave.2", tint: .pink, title: "Alert") {
                Picker("", selection: $draft.alertType) {
                    ForEach(AlertType.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
        }
    }

    // MARK: Place

    @ViewBuilder private var placeRows: some View {
        AttributeRow(symbol: "location", tint: .green, title: "Place") {
            if let location = draft.location {
                HStack(spacing: 8) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(location.placeName ?? location.address).lineLimit(1)
                        if location.placeName != nil { Text(location.address).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Button("Change") { showLocationPicker = true }.controlSize(.small)
                    Button { draft.location = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Remove place")
                }
            } else {
                Button("Add place…") { showLocationPicker = true }.controlSize(.small)
            }
        }
        if let location = draft.location {
            AttributeRow(symbol: "figure.walk", tint: .mint, title: "Trigger") {
                Picker("", selection: Binding(get: { location.transition }, set: { draft.location?.transition = $0 })) {
                    ForEach(ReminderLocation.Transition.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
        }
    }
}

/// Rounded card that stacks attribute rows with hairline separators.
struct AttributeCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { _VariadicView.Tree(_DividedRows()) { content } }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Inserts a divider between sibling rows without knowing how many there are.
private struct _DividedRows: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        ForEach(children) { child in
            child
            if child.id != children.last?.id { Divider().padding(.leading, 44) }
        }
    }
}

struct AttributeRow<Control: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 24, height: 24).background(tint.gradient, in: RoundedRectangle(cornerRadius: 6))
            Text(title).lineLimit(1).layoutPriority(1)
            Spacer(minLength: 8)
            control.fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

struct RepeatPicker: View {
    @Binding var rule: RepeatRule?
    let allDay: Bool

    private var units: [RepeatRule.Unit] { allDay ? [.day, .week, .month, .year] : RepeatRule.Unit.allCases }

    var body: some View {
        HStack(spacing: 8) {
            if rule != nil {
                Stepper("every \(rule?.interval ?? 1)", value: Binding(get: { rule?.interval ?? 1 }, set: { rule?.interval = $0 }), in: 1...999)
                    .font(.callout)
            }
            Picker("", selection: Binding(get: { rule?.unit }, set: { unit in
                rule = unit.map { RepeatRule(unit: $0, interval: rule?.interval ?? 1) }
            })) {
                Text("Never").tag(RepeatRule.Unit?.none)
                ForEach(units, id: \.self) { Text($0.label + ((rule?.interval ?? 1) > 1 ? "s" : "")).tag(RepeatRule.Unit?.some($0)) }
            }
            .labelsHidden().fixedSize()
        }
    }
}

struct EarlyAlertPicker: View {
    @Binding var alert: EarlyAlert?

    var body: some View {
        HStack(spacing: 8) {
            if let current = alert {
                Stepper("\(current.offset)", value: Binding(get: { current.offset }, set: { alert?.offset = $0 }), in: 1...999).font(.callout)
                Picker("", selection: Binding(get: { current.unit }, set: { alert?.unit = $0 })) {
                    ForEach(EarlyAlert.Unit.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
                Text("before").font(.callout).foregroundStyle(.secondary)
            }
            Toggle("", isOn: Binding(get: { alert != nil }, set: { alert = $0 ? EarlyAlert(offset: 1, unit: .day) : nil }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

/// Address search through Apple's MapKit (sandbox-safe, no API key).
struct LocationPicker: View {
    struct Place: Identifiable {
        let id = UUID()
        let name: String?
        let address: String
        let latitude: Double
        let longitude: Double
    }

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Place] = []
    @State private var searching = false
    @State private var error: String?
    let onPick: (Place) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a place").font(.title3.weight(.semibold))
            HStack {
                TextField("Search an address or place", text: $query).textFieldStyle(.roundedBorder).onSubmit(search)
                Button("Search", action: search).disabled(query.trimmingCharacters(in: .whitespaces).count < 3 || searching)
            }
            if searching { ProgressView().controlSize(.small) }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            List(results) { place in
                Button {
                    onPick(place)
                    dismiss()
                } label: {
                    VStack(alignment: .leading) {
                        Text(place.name ?? place.address)
                        if place.name != nil { Text(place.address).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 220)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 3, text.count <= 200 else { return }
        searching = true
        error = nil
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        Task {
            defer { searching = false }
            do {
                let response = try await MKLocalSearch(request: request).start()
                results = response.mapItems.prefix(15).map { item in
                    let coordinate = item.placemark.coordinate
                    return Place(name: item.name, address: item.placemark.title ?? item.name ?? "",
                                 latitude: coordinate.latitude, longitude: coordinate.longitude)
                }
                if results.isEmpty { error = "No places found." }
            } catch {
                self.error = "Search failed. Check your connection."
            }
        }
    }
}
