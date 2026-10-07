import SwiftUI
import MapKit

/// Live place suggestions while the user types (cities, addresses, venues).
@MainActor
final class PlaceSearchModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query = "" {
        didSet { if query != oldValue { updateQuery() } }
    }
    @Published private(set) var results: [MKLocalSearchCompletion] = []
    @Published private(set) var isResolving = false

    private let completer = MKLocalSearchCompleter()
    /// Set right after a pick, so writing the picked name doesn't reopen the list.
    private var skipNextUpdate = false

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    /// Ranks nearby matches first without hiding far ones.
    func prefer(near coordinate: CLLocationCoordinate2D?) {
        guard let coordinate else { return }
        completer.region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 200_000,
            longitudinalMeters: 200_000
        )
    }

    func setPicked(name: String) {
        skipNextUpdate = true
        query = name
        skipNextUpdate = false
        results = []
    }

    private func updateQuery() {
        guard !skipNextUpdate else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            completer.cancel()
            results = []
        } else {
            completer.queryFragment = text
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            results = Array(completer.results.prefix(6))
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            results = []
        }
    }

    /// The coordinate behind a suggestion.
    func resolve(_ completion: MKLocalSearchCompletion) async -> EventPlace? {
        isResolving = true
        defer { isResolving = false }
        let request = MKLocalSearch.Request(completion: completion)
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        let coordinate = item.placemark.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let title = completion.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return EventPlace(
            name: title.isEmpty ? (item.name ?? "") : title,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }
}

/// A search field whose suggestions open under it as the user types. Tapping a
/// suggestion finds it on the map and hands back the place. Meant for a `Form`.
struct PlaceSearchField: View {
    var placeholder: String
    @Binding var text: String
    /// The picked place, cleared as soon as the user edits the text again.
    @Binding var picked: EventPlace?
    var near: CLLocationCoordinate2D? = nil

    @StateObject private var model = PlaceSearchModel()
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: picked == nil ? "magnifyingglass" : "mappin.circle.fill")
                    .foregroundStyle(picked == nil ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(Color.accentColor))
                TextField(placeholder, text: $model.query)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.search)
                if model.isResolving {
                    ProgressView()
                } else if !model.query.isEmpty {
                    Button {
                        model.query = ""
                        focused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "place_search_clear"))
                }
            }
            ForEach(model.results, id: \.self) { completion in
                Button {
                    Task { await choose(completion) }
                } label: {
                    HStack(spacing: DS.Spacing.sm) {
                        Image(systemName: "mappin.and.ellipse")
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(completion.title)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if !completion.subtitle.isEmpty {
                                Text(completion.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isResolving)
            }
        }
        .onAppear {
            model.prefer(near: near)
            if picked != nil {
                model.setPicked(name: text)
            } else {
                model.query = text
            }
        }
        .onChange(of: model.query) { _, newValue in
            if newValue != text { text = newValue }
            if let current = picked, newValue != current.name { picked = nil }
        }
    }

    private func choose(_ completion: MKLocalSearchCompletion) async {
        guard let place = await model.resolve(completion) else { return }
        picked = place
        text = place.name
        model.setPicked(name: place.name)
        focused = false
    }
}
