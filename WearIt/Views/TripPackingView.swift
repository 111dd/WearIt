import SwiftUI
import SwiftData
import CoreLocation

/// Suitcase for one trip: a look per day, closet pieces for the weather,
/// and quantity lines (underwear, socks, swimwear) the user can edit.
struct TripPackingView: View {
    let trip: TripSpan
    let garments: [Garment]
    var onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \UserProfile.createdAt, order: .reverse) private var profiles: [UserProfile]

    @State private var list: PackingList
    @State private var forecasts: [DayForecast] = []
    @State private var isGenerating = false
    @State private var swap: PackingSwap?

    init(trip: TripSpan, garments: [Garment], onDelete: (() -> Void)? = nil) {
        self.trip = trip
        self.garments = garments
        self.onDelete = onDelete
        _list = State(initialValue: TripPackingStore.list(for: trip.id) ?? .empty(tripID: trip.id))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                    header
                    if isGenerating {
                        ProgressView(String(localized: "trip_generating"))
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }
                    if !list.days.isEmpty {
                        daysSection
                    } else if !isGenerating, garments.isEmpty {
                        Text(String(localized: "trip_no_clothes"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !list.quantities.isEmpty || !list.bagGarmentIDs.isEmpty {
                        bagSection
                    }
                    if onDelete != nil {
                        Button(role: .destructive) {
                            onDelete?()
                            dismiss()
                        } label: {
                            Text(String(localized: "trip_delete"))
                                .frame(maxWidth: .infinity)
                        }
                        .dsSecondaryButton()
                    }
                }
                .padding(DS.Spacing.md)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(String(localized: "trip_packing_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_done")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(String(localized: "trip_rebuild"), systemImage: "arrow.clockwise") {
                        Task { await rebuild() }
                    }
                    .disabled(isGenerating || garments.isEmpty)
                }
            }
        }
        .task(id: trip.id) { await prepare() }
        .sheet(item: $swap) { target in
            swapSheet(target)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(trip.placeName.isEmpty ? trip.title : trip.placeName)
                .font(.title3.weight(.bold))
            Text(rangeText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let note = climateNote {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var rangeText: String {
        let start = trip.start.formatted(.dateTime.day().month(.abbreviated))
        let end = trip.end.formatted(.dateTime.day().month(.abbreviated))
        if Calendar.current.isDate(trip.start, inSameDayAs: trip.end) { return start }
        return "\(start)–\(end)"
    }

    private var matchedForecasts: [DayForecast] {
        trip.days().compactMap { EventLocationForecastService.match(forecasts, to: $0) }
    }

    private var climateNote: String? {
        let climate = TripPackingBuilder.climate(forecasts: matchedForecasts)
        if trip.place == nil {
            return String(localized: "trip_no_place_weather")
        }
        if matchedForecasts.isEmpty {
            return String(localized: "trip_weather_later")
        }
        if climate.suggestsSwim && climate.suggestsCoat {
            return String(localized: "trip_mixed_note")
        }
        if climate.suggestsSwim { return String(localized: "trip_hot_note") }
        if climate.suggestsCoat { return String(localized: "trip_cold_note") }
        return nil
    }

    // MARK: Days

    private var daysSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            DSSectionHeader(String(localized: "trip_suggested_days"), icon: "tshirt")
            ForEach(list.days) { day in
                dayCard(day)
            }
        }
    }

    private func dayCard(_ day: PackingDay) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack {
                Text(day.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                if let forecast = EventLocationForecastService.match(forecasts, to: day.date) {
                    Text("\(Int(forecast.lowTempC.rounded()))°–\(Int(forecast.highTempC.rounded()))°")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if day.slotGarments.isEmpty {
                Text(String(localized: "trip_day_empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: DS.Spacing.sm) {
                        ForEach(OutfitSlot.allCases, id: \.rawValue) { slot in
                            if let id = day.slotGarments[slot.rawValue], let garment = byID[id] {
                                dayPiece(day: day, slot: slot, garment: garment)
                            }
                        }
                    }
                }
            }
        }
        .padding(DS.Spacing.sm)
        .liquidGlassSurface(cornerRadius: DS.Radius.md, castsShadow: false)
    }

    private func dayPiece(day: PackingDay, slot: OutfitSlot, garment: Garment) -> some View {
        VStack(spacing: DS.Spacing.xxs) {
            DSGarmentThumbnail(garment, size: .small)
            Text(slot.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Menu {
                Button(String(localized: "trip_swap"), systemImage: "arrow.triangle.2.circlepath") {
                    swap = PackingSwap(dayStamp: day.dayStamp, slot: slot, currentID: garment.id)
                }
                Button(String(localized: "trip_remove"), systemImage: "minus.circle", role: .destructive) {
                    remove(slot: slot, on: day.dayStamp)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.bold))
                    .frame(width: 44, height: 28)
            }
            .accessibilityLabel(String(localized: "trip_edit_piece"))
        }
        .frame(width: 72)
    }

    // MARK: Bag

    private var bagSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            DSSectionHeader(String(localized: "trip_in_the_bag"), icon: "suitcase")
            ForEach(list.bagGarmentIDs, id: \.self) { id in
                if let garment = byID[id] {
                    garmentRow(garment)
                }
            }
            if !list.quantities.isEmpty {
                DSSectionHeader(String(localized: "trip_basics"), icon: "number")
                ForEach(list.quantities) { line in
                    quantityRow(line)
                }
            }
        }
    }

    private func garmentRow(_ garment: Garment) -> some View {
        let packed = list.packedGarmentIDs.contains(garment.id)
        let days = wearingDays(garment.id)
        return HStack(spacing: DS.Spacing.sm) {
            Button {
                togglePacked(garment.id)
            } label: {
                Image(systemName: packed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(packed ? Color.accentColor : .secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: packed ? "trip_packed" : "trip_mark_packed"))
            DSGarmentThumbnail(garment, size: .small)
            VStack(alignment: .leading, spacing: 2) {
                Text(garment.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if days > 1 {
                    Text(String(format: String(localized: "trip_days_wearing_format"), days))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if list.extraGarmentIDs.contains(garment.id) {
                    Text(String(localized: "trip_from_closet"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if list.extraGarmentIDs.contains(garment.id) {
                Button(role: .destructive) {
                    list.extraGarmentIDs.removeAll { $0 == garment.id }
                    list.packedGarmentIDs.removeAll { $0 == garment.id }
                    TripPackingStore.save(list)
                } label: {
                    Image(systemName: "minus.circle")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "trip_remove"))
            }
        }
    }

    private func quantityRow(_ line: TripPackingBuilder.Quantity) -> some View {
        let index = list.quantities.firstIndex { $0.id == line.id }
        return HStack(spacing: DS.Spacing.sm) {
            Button {
                guard let index else { return }
                list.quantities[index].packed.toggle()
                TripPackingStore.save(list)
            } label: {
                Image(systemName: line.packed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(line.packed ? Color.accentColor : .secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(line.count == 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(quantityTitle(line.id))
                    .font(.subheadline.weight(.semibold))
                Stepper(
                    value: Binding(
                        get: { list.quantities.first { $0.id == line.id }?.count ?? 0 },
                        set: { newValue in
                            guard let index else { return }
                            list.quantities[index].count = newValue
                            if newValue == 0 { list.quantities[index].packed = false }
                            TripPackingStore.save(list)
                        }
                    ),
                    in: 0...30
                ) {
                    Text("\(line.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func quantityTitle(_ id: String) -> String {
        switch id {
        case "underwear": return String(localized: "trip_quantity_underwear")
        case "socks": return String(localized: "trip_quantity_socks")
        case "swim": return String(localized: "trip_quantity_swim")
        case "coat": return String(localized: "trip_quantity_coat")
        default: return id
        }
    }

    // MARK: Swap

    private func swapSheet(_ target: PackingSwap) -> some View {
        NavigationStack {
            List(alternatives(for: target.slot, current: target.currentID)) { garment in
                Button {
                    assign(garment.id, to: target.slot, on: target.dayStamp)
                    swap = nil
                } label: {
                    HStack(spacing: DS.Spacing.sm) {
                        DSGarmentThumbnail(garment, size: .small)
                        Text(garment.displayTitle)
                            .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle(target.slot.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_close")) { swap = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func alternatives(for slot: OutfitSlot, current: UUID?) -> [Garment] {
        garments
            .filter {
                slot.allowedCategories.contains($0.category)
                    && !$0.isBlocked
                    && !$0.isCurrentlyUnavailable
                    && $0.id != current
            }
            .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    // MARK: Edits

    private var byID: [UUID: Garment] {
        Dictionary(garments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func wearingDays(_ id: UUID) -> Int {
        list.days.filter { $0.slotGarments.values.contains(id) }.count
    }

    private func togglePacked(_ id: UUID) {
        if let index = list.packedGarmentIDs.firstIndex(of: id) {
            list.packedGarmentIDs.remove(at: index)
        } else {
            list.packedGarmentIDs.append(id)
        }
        TripPackingStore.save(list)
    }

    private func remove(slot: OutfitSlot, on stamp: TimeInterval) {
        guard let index = list.days.firstIndex(where: { $0.dayStamp == stamp }) else { return }
        list.days[index].slotGarments.removeValue(forKey: slot.rawValue)
        TripPackingStore.save(list)
    }

    private func assign(_ id: UUID, to slot: OutfitSlot, on stamp: TimeInterval) {
        guard let index = list.days.firstIndex(where: { $0.dayStamp == stamp }) else { return }
        list.days[index].slotGarments[slot.rawValue] = id
        TripPackingStore.save(list)
    }

    // MARK: Build

    private func prepare() async {
        guard !isGenerating else { return }
        if let place = trip.place {
            let today = Calendar.current.startOfDay(for: Date())
            let ahead = Calendar.current.dateComponents([.day], from: today, to: trip.end).day ?? 0
            let count = min(16, max(1, ahead + 1))
            forecasts = await EventLocationForecastService.shared.forecasts(for: place, days: count)
        }
        if list.days.isEmpty, !garments.isEmpty {
            await generate(keeping: [], packed: [])
        } else if list.quantities.isEmpty {
            list.quantities = freshQuantities(keeping: [])
            TripPackingStore.save(list)
        }
    }

    private func rebuild() async {
        let kept = list.quantities
        let packed = list.packedGarmentIDs
        list.days = []
        list.extraGarmentIDs = []
        await generate(keeping: kept, packed: packed)
    }

    private func generate(keeping oldQuantities: [TripPackingBuilder.Quantity], packed: [UUID]) async {
        isGenerating = true
        defer { isGenerating = false }
        let pool = garments.filter { !$0.isBlocked && !$0.isCurrentlyUnavailable }
        let profileID = profiles.first?.id
        var days: [PackingDay] = []
        var usedRotation: Set<UUID> = []
        for day in trip.days() {
            let forecast = EventLocationForecastService.match(forecasts, to: day)
            let outfit = suggest(on: day, forecast: forecast, pool: pool, profileID: profileID, excluding: usedRotation)
            var slots: [String: UUID] = [:]
            for garment in outfit {
                let slot = OutfitSlot.from(category: garment.category)
                if slots[slot.rawValue] == nil {
                    slots[slot.rawValue] = garment.id
                }
                if slot == .top || slot == .bottom || slot == .shoes {
                    usedRotation.insert(garment.id)
                }
            }
            days.append(PackingDay(dayStamp: day.timeIntervalSince1970, slotGarments: slots))
            await Task.yield()
        }
        let climate = TripPackingBuilder.climate(forecasts: matchedForecasts)
        let coats = climate.suggestsCoat
            ? TripPackingBuilder.coatCandidates(pool, veryCold: (climate.averageLow ?? 20) <= 5)
            : []
        let swim = climate.suggestsSwim ? TripPackingBuilder.swimCandidates(pool) : []
        let dayIDs = Set(days.flatMap { $0.slotGarments.values })
        list.days = days
        list.extraGarmentIDs = (coats + swim).map(\.id).filter { !dayIDs.contains($0) }
        list.packedGarmentIDs = packed.filter { list.bagGarmentIDs.contains($0) }
        list.quantities = freshQuantities(keeping: oldQuantities)
        TripPackingStore.save(list)
    }

    private func freshQuantities(keeping old: [TripPackingBuilder.Quantity]) -> [TripPackingBuilder.Quantity] {
        let climate = TripPackingBuilder.climate(forecasts: matchedForecasts)
        let hasCoat = !TripPackingBuilder.coatCandidates(
            garments.filter { !$0.isBlocked && !$0.isCurrentlyUnavailable },
            veryCold: true
        ).isEmpty
        let fresh = TripPackingBuilder.quantities(
            dayCount: trip.dayCount,
            climate: climate,
            hasCoatInCloset: hasCoat
        )
        return fresh.map { line in
            guard let previous = old.first(where: { $0.id == line.id }) else { return line }
            return TripPackingBuilder.Quantity(id: line.id, count: previous.count, packed: previous.packed)
        }
    }

    private func suggest(
        on day: Date,
        forecast: DayForecast?,
        pool: [Garment],
        profileID: UUID?,
        excluding: Set<UUID>
    ) -> [Garment] {
        guard !pool.isEmpty else { return [] }
        let temperature: Double
        let raining: Bool
        let diurnal: DiurnalTemps?
        let samples: [ThermalWeatherSample]
        if let forecast {
            let profile = DayTemperatureProfile(from: forecast)
            temperature = profile.effectiveTemp
            raining = forecast.isRaining
            diurnal = DiurnalTemps(profile: profile)
            samples = forecast.thermalSamples(for: .day, now: day)
        } else {
            temperature = 22
            raining = false
            diurnal = nil
            samples = []
        }
        let context = RecoContext(
            desiredFormality: 2,
            temperatureC: temperature,
            isRaining: raining,
            now: day,
            profileID: profileID,
            lookTime: .day,
            occasionKind: .travel,
            diurnal: diurnal,
            thermalSamples: samples,
            allowRepeatedItems: true
        )
        var outfit = AIRecommender.shared.suggestOutfit(
            from: pool,
            ctx: context,
            modelContext: self.context,
            excludedIDs: excluding
        )
        if outfit.isEmpty, !excluding.isEmpty {
            outfit = AIRecommender.shared.suggestOutfit(
                from: pool,
                ctx: context,
                modelContext: self.context
            )
        }
        return outfit
    }
}

private struct PackingSwap: Identifiable {
    var dayStamp: TimeInterval
    var slot: OutfitSlot
    var currentID: UUID?
    var id: String { "\(dayStamp)-\(slot.rawValue)" }
}

/// Dates and a destination, for a trip that is not on the calendar.
struct PlanTripSheet: View {
    var onCreate: (TripSpan) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var placeName = ""
    @State private var pickedPlace: EventPlace?
    @State private var start = Calendar.current.startOfDay(for: Date())
    @State private var end = Calendar.current.date(byAdding: .day, value: 3, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    @State private var isSaving = false
    @State private var failedGeocode = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PlaceSearchField(
                        placeholder: String(localized: "trip_destination_placeholder"),
                        text: $placeName,
                        picked: $pickedPlace,
                        near: WeatherCenter.shared.homeCoordinate?.location
                    )
                } footer: {
                    if failedGeocode {
                        Text(String(localized: "trip_geocode_failed"))
                    }
                }
                Section {
                    DatePicker(String(localized: "trip_start"), selection: $start, displayedComponents: .date)
                    DatePicker(String(localized: "trip_end"), selection: $end, in: start..., displayedComponents: .date)
                }
            }
            .navigationTitle(String(localized: "trip_manual_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_close")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "trip_save")) { Task { await save() } }
                        .disabled(placeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        let name = placeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        let startDay = Calendar.current.startOfDay(for: start)
        let endDay = Calendar.current.startOfDay(for: max(start, end))
        var latitude: Double?
        var longitude: Double?
        var resolvedName = name
        var found = pickedPlace
        if found == nil { found = await Self.geocode(name) }
        if let place = found {
            latitude = place.latitude
            longitude = place.longitude
            if !place.name.isEmpty { resolvedName = place.name }
        } else if !failedGeocode {
            failedGeocode = true
            return
        }
        let place = latitude == nil ? nil : EventPlace(name: resolvedName, latitude: latitude!, longitude: longitude!)
        let trip = TripSpan(
            id: TripFinder.makeID(start: startDay, end: endDay, place: place),
            title: resolvedName,
            start: startDay,
            end: endDay,
            placeName: resolvedName,
            latitude: latitude,
            longitude: longitude,
            isManual: true
        )
        onCreate(trip)
        dismiss()
    }

    private static func geocode(_ query: String) async -> EventPlace? {
        let geocoder = CLGeocoder()
        guard let mark = try? await geocoder.geocodeAddressString(query).first,
              let location = mark.location else { return nil }
        let name = mark.locality ?? mark.administrativeArea ?? query
        return EventPlace(
            name: name,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
    }
}
