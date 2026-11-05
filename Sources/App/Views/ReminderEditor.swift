import MapKit
import SwiftUI

/// One form for creating and editing. The caller owns the draft and decides when to save.
struct ReminderEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: ReminderDraft
    @State private var newItem = ""
    @State private var showLocationPicker = false

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

    var body: some View {
        Form {
            Section {
                TextField("", text: $draft.title, prompt: Text("Title")).labelsHidden().font(.title3)
                TextField("", text: $draft.text, prompt: Text("Notes"), axis: .vertical).labelsHidden().lineLimit(2...8)
                Picker("List", selection: $draft.categoryID) {
                    Text("My reminders").tag(defaultCategoryID)
                    ForEach(model.snapshot.categories) { Text($0.name).tag($0.id) }
                }
                Toggle("Important", isOn: $draft.favorite)
            }

            Section("Checklist") {
                ForEach($draft.checklist.indices, id: \.self) { index in
                    HStack {
                        Toggle("", isOn: $draft.checklist[index].done).labelsHidden().toggleStyle(.checkbox)
                        TextField("", text: $draft.checklist[index].text, prompt: Text("Item")).labelsHidden()
                            .strikethrough(draft.checklist[index].done)
                        Button { draft.checklist.remove(at: index) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel("Remove item")
                    }
                }
                HStack {
                    TextField("", text: $newItem, prompt: Text("Add item")).labelsHidden().onSubmit(addItem)
                    Button("Add", action: addItem).disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("Time") {
                Picker("Remind", selection: scheduleKind) {
                    Text("No time").tag(0)
                    Text("At a time").tag(1)
                    Text("On a day").tag(2)
                }
                .pickerStyle(.segmented)
                if case .timed = draft.schedule {
                    DatePicker("When", selection: scheduleDate, displayedComponents: [.date, .hourAndMinute])
                } else if case .allDay = draft.schedule {
                    DatePicker("Day", selection: scheduleDate, displayedComponents: [.date])
                }
                if draft.schedule.date != nil {
                    RepeatPicker(rule: $draft.repeatRule, allDay: { if case .allDay = draft.schedule { true } else { false } }())
                    EarlyAlertPicker(alert: $draft.earlyAlert)
                    Picker("Alert", selection: $draft.alertType) {
                        ForEach(AlertType.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
            }

            Section("Place") {
                if let location = draft.location {
                    LabeledContent("Where") {
                        VStack(alignment: .trailing) {
                            Text(location.placeName ?? location.address).lineLimit(1)
                            if location.placeName != nil { Text(location.address).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }
                    Picker("Trigger", selection: Binding(get: { location.transition }, set: { draft.location?.transition = $0 })) {
                        ForEach(ReminderLocation.Transition.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    HStack {
                        Button("Change place…") { showLocationPicker = true }
                        Button("Remove place") { draft.location = nil }
                    }
                } else {
                    Button("Add place…") { showLocationPicker = true }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showLocationPicker) {
            LocationPicker { place in
                draft.location = ReminderLocation(latitude: place.latitude, longitude: place.longitude, address: place.address,
                                                  placeName: place.name, transition: draft.location?.transition ?? .arrive)
            }
        }
    }

    private func addItem() {
        let text = newItem.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, draft.checklist.count < 200 else { return }
        draft.checklist.append(.init(text: text, done: false))
        newItem = ""
    }
}

struct RepeatPicker: View {
    @Binding var rule: RepeatRule?
    let allDay: Bool

    private var units: [RepeatRule.Unit] { allDay ? [.day, .week, .month, .year] : RepeatRule.Unit.allCases }

    var body: some View {
        Picker("Repeat", selection: Binding(get: { rule?.unit }, set: { unit in
            rule = unit.map { RepeatRule(unit: $0, interval: rule?.interval ?? 1) }
        })) {
            Text("Never").tag(RepeatRule.Unit?.none)
            ForEach(units, id: \.self) { Text("Every \($0.label)").tag(RepeatRule.Unit?.some($0)) }
        }
        if rule != nil {
            Stepper("Every \(rule?.interval ?? 1) \(rule?.unit.label ?? "")\((rule?.interval ?? 1) > 1 ? "s" : "")",
                    value: Binding(get: { rule?.interval ?? 1 }, set: { rule?.interval = $0 }), in: 1...999)
        }
    }
}

struct EarlyAlertPicker: View {
    @Binding var alert: EarlyAlert?

    var body: some View {
        Toggle("Early reminder", isOn: Binding(get: { alert != nil }, set: { alert = $0 ? EarlyAlert(offset: 1, unit: .day) : nil }))
        if let current = alert {
            HStack {
                Stepper("\(current.offset)", value: Binding(get: { current.offset }, set: { alert?.offset = $0 }), in: 1...999)
                Picker("", selection: Binding(get: { current.unit }, set: { alert?.unit = $0 })) {
                    ForEach(EarlyAlert.Unit.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                Text("before")
            }
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
                    let address = item.placemark.title ?? item.name ?? ""
                    return Place(name: item.name, address: address, latitude: coordinate.latitude, longitude: coordinate.longitude)
                }
                if results.isEmpty { error = "No places found." }
            } catch {
                self.error = "Search failed. Check your connection."
            }
        }
    }
}
