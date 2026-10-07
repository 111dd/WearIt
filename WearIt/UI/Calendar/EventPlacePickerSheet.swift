import SwiftUI

/// Pick the real place behind an event's typed location from a live search
/// list. The pick is kept for that text, so every event with it uses it.
struct EventPlacePickerSheet: View {
    let eventTitle: String
    let query: String

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var picked: EventPlace?
    @State private var hadUserPick: Bool

    init(eventTitle: String, query: String) {
        self.eventTitle = eventTitle
        self.query = query
        let resolver = TypedEventPlaceResolver.shared
        let current = resolver.isUserPicked(query) ? resolver.place(for: query, allowGuess: false) : nil
        _text = State(initialValue: current?.name ?? query)
        _picked = State(initialValue: current)
        _hadUserPick = State(initialValue: current != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PlaceSearchField(
                        placeholder: String(localized: "event_place_search_placeholder"),
                        text: $text,
                        picked: $picked,
                        near: WeatherCenter.shared.homeCoordinate?.location
                    )
                } header: {
                    Text(eventTitle)
                } footer: {
                    Text(String(localized: "event_place_search_footer"))
                }
                if hadUserPick {
                    Section {
                        Button(String(localized: "event_place_clear"), role: .destructive) {
                            apply(nil)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "event_place_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_close")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "event_place_save")) { apply(picked) }
                        .disabled(picked == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func apply(_ place: EventPlace?) {
        TypedEventPlaceResolver.shared.setUserPlace(place, for: query)
        CalendarContextService.shared.invalidateCache()
        // The planner and the calendar re-read events and re-dress uncommitted looks.
        NotificationCenter.default.post(name: .calendarUnderstandingChanged, object: nil)
        dismiss()
    }
}
