import SwiftUI
import SwiftData
import UIKit

struct OutfitView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var weather: WeatherCenter

    @Query(sort: \Garment.createdAt, order: .reverse) private var allGarments: [Garment]

    @State private var desiredFormality: Double = 3
    @State private var temperatureC: Double = 22
    @State private var isRaining: Bool = false
    @State private var suggested: [Garment] = []
    @State private var userRating: Double = 4

    @State private var locked: Garment? = nil

    @State private var forecastStatus: String = ""

    @State private var feedbackMessage: String?
    @State private var showFeedback: Bool = false
    
    // Track shown garments for negative sampling in learning
    @State private var shownCandidates: [Garment] = []
    @State private var currentDate: Date = Date()

    // Available garments (not blocked, not in laundry)
    private var availableGarments: [Garment] {
        allGarments.filter { !$0.isBlocked && !$0.isCurrentlyUnavailable }
    }

    // Signature for changes to trigger refresh
    private var garmentsSignature: String {
        guard !allGarments.isEmpty else { return "" }
        let ids = allGarments.map { "\($0.persistentModelID)" }
        let flags = allGarments.map { "\($0.isBlocked ? "1" : "0")\($0.isCurrentlyUnavailable ? "1" : "0")" }
        return zip(ids, flags).map { "\($0.0):\($0.1)" }.joined(separator: ",")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidGlassBackdrop()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {

                        // Greeting & Forecast
                        VStack(alignment: .leading, spacing: 8) {
                            Text(greeting())
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                            
                            HStack(spacing: 6) {
                                Image(systemName: isRaining ? "cloud.rain.fill" : "sun.max.fill")
                                    .foregroundStyle(isRaining ? .blue : .orange)
                                Text(forecastLine())
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 20)

                        // Featured Outfit
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Today's Recommendation")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            
                            OutfitGrid(items: suggested)
                                .padding(12)
                                .glassCard(corner: 28, intensity: .ultraThin)
                        }

                        // Controls
                        VStack(spacing: 24) {
                            controlRow(title: "Formality", value: $desiredFormality, range: 1...5, systemImage: "briefcase.fill")
                            controlRow(title: "Temperature", value: $temperatureC, range: -5...40, systemImage: "thermometer.medium", suffix: "°C")
                            
                            Toggle(isOn: $isRaining) {
                                Label("Raining", systemImage: "cloud.rain.fill")
                                    .font(.subheadline.bold())
                            }
                            .tint(.accentColor)
                        }
                        .padding(20)
                        .glassCard(corner: 24)

                        // Quick Actions
                        if !suggested.isEmpty {
                            VStack(spacing: 12) {
                                Button {
                                    feedback.impactOccurred(intensity: 1.0)
                                    markAsWornAndSave()
                                } label: {
                                    Label("Wear This Outfit", systemImage: "checkmark.seal.fill")
                                        .font(.headline)
                                        .frame(maxWidth: .infinity)
                                }
                                .glassButton(cornerRadius: 20)
                                .tint(.accentColor)

                                HStack(spacing: 12) {
                                    Button {
                                        feedback.impactOccurred(intensity: 0.7)
                                        likeCurrentOutfit()
                                    } label: {
                                        Label("Favorite", systemImage: "heart.fill")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .glassButton(cornerRadius: 18)
                                    .foregroundStyle(.pink)

                                    Button {
                                        feedback.impactOccurred(intensity: 0.5)
                                        refreshSuggestion()
                                    } label: {
                                        Label("Refresh", systemImage: "arrow.clockwise")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .glassButton(cornerRadius: 18)
                                }
                            }
                        }
                        
                        // Garment Lock Selection
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Lock a Piece")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            
                            lockStrip
                        }

                        Spacer(minLength: 100)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .navigationTitle("Outfit")
            .navigationBarTitleDisplayMode(.inline)

            .onAppear {
                applyWeatherSnapshot()
                refreshSuggestion()
            }
            .alert("עדכון", isPresented: $showFeedback, presenting: feedbackMessage) { _ in
                Button("סגור", role: .cancel) { }
            } message: { msg in
                Text(msg)
            }
            // WeatherCenter מפרסם ערכים — מרעננים אוטומטית (עם debounce)
            .onChange(of: weather.currentTempC) { oldValue, newValue in
                guard oldValue != newValue else { return }
                applyWeatherSnapshot()
                refreshSuggestion()
            }
            .onChange(of: weather.isRainingNow) { oldValue, newValue in
                guard oldValue != newValue else { return }
                applyWeatherSnapshot()
                refreshSuggestion()
            }
            .onChange(of: desiredFormality) { oldValue, newValue in
                guard oldValue != newValue else { return }
                refreshSuggestion()
            }
            .onChange(of: temperatureC) { oldValue, newValue in
                guard abs(oldValue - newValue) > 0.5 else { return }
                refreshSuggestion()
            }
            .onChange(of: isRaining) { oldValue, newValue in
                guard oldValue != newValue else { return }
                refreshSuggestion()
            }
            .onChange(of: allGarments.count) { _, _ in
                refreshSuggestion()
            }
            .onChange(of: garmentsSignature) { oldValue, newValue in
                guard oldValue != newValue else { return }
                refreshSuggestion()
            }
            .onChange(of: locked?.persistentModelID) { oldValue, newValue in
                guard oldValue != newValue else { return }
                refreshSuggestion()
            }
            .onReceive(NotificationCenter.default.publisher(for: .garmentAdded)) { _ in
                refreshSuggestion()
            }
        }
        .onAppear {
            refreshCurrentDate()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshCurrentDate()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            refreshCurrentDate()
        }
    }

    // MARK: - Sections

    private var controls: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Formality: \(Int(desiredFormality))", systemImage: "star.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Slider(value: $desiredFormality, in: 1...5, step: 1)
                .tint(.accentColor)
            
            HStack {
                Label("Temp: \(Int(temperatureC))℃", systemImage: "thermometer")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Slider(value: $temperatureC, in: -5...40, step: 1)
                .tint(.accentColor)
            
            Toggle(isOn: $isRaining) {
                Label("Raining", systemImage: "cloud.rain")
                    .font(.subheadline)
            }
            .tint(.accentColor)
        }
        .glassCard(corner: 20, intensity: .thin)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            // דירוג לוק
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("דירוג הלוק (1-5)", systemImage: "star.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f", userRating))
                        .font(.subheadline.weight(.semibold))
                }
                Slider(value: $userRating, in: 1...5, step: 1)
                    .tint(.yellow)
            }
            .glassCard(corner: 16, intensity: .thin)

            Button {
                markAsWornAndSave()
            } label: {
                Label("לבשתי ושמור", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
                    .fontWeight(.semibold)
            }
            .glassButton(cornerRadius: 16, material: .thinMaterial)

            Button {
                likeCurrentOutfit()
            } label: {
                Label("אהבתי / מועדף", systemImage: "heart.fill")
                    .frame(maxWidth: .infinity)
                    .fontWeight(.semibold)
            }
            .glassButton(cornerRadius: 16, material: .thinMaterial)

            Button {
                saveForLater()
            } label: {
                Label("שמור לוק (ללא סימון לבוש)", systemImage: "bookmark.fill")
                    .frame(maxWidth: .infinity)
                    .fontWeight(.medium)
            }
            .glassButton(cornerRadius: 16, material: .thinMaterial)

            Button(role: .destructive) {
                banCurrentOutfit()
            } label: {
                Label("אל תציע את הסט הזה שוב", systemImage: "xmark.circle.fill")
                    .frame(maxWidth: .infinity)
                    .fontWeight(.medium)
            }
            .glassButton(cornerRadius: 16, material: .thinMaterial)
        }
        .glassCard(corner: 20, intensity: .thin)
    }

    private var lockStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Select a piece to build around").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if locked != nil {
                    Button("Clear") { 
                        feedback.impactOccurred(intensity: 0.3)
                        locked = nil 
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(allGarments) { g in
                        LockTile(
                            g: g,
                            isLocked: g.persistentModelID == locked?.persistentModelID,
                            isUnavailable: g.isCurrentlyUnavailable
                        )
                        .onTapGesture {
                            feedback.impactOccurred(intensity: 0.5)
                            if locked?.persistentModelID == g.persistentModelID {
                                locked = nil
                            } else {
                                locked = g
                            }
                        }
                        .contextMenu {
                            if g.isCurrentlyUnavailable {
                                Button("Mark as Available") {
                                    g.markAvailableNow()
                                    try? context.save()
                                    refreshSuggestion()
                                }
                            } else {
                                Button("Mark as Laundry (48h)") {
                                    g.markUnavailableForTwoDays()
                                    try? context.save()
                                    refreshSuggestion()
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func controlRow(title: String, value: Binding<Double>, range: ClosedRange<Double>, systemImage: String, suffix: String = "") -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value.wrappedValue))\(suffix)")
                    .font(.subheadline.bold())
                    .foregroundColor(.accentColor)
            }
            Slider(value: value, in: range, step: 1)
                .tint(.accentColor)
        }
    }

    private let feedback = UIImpactFeedbackGenerator(style: .medium)

    // MARK: - Helpers

    private func greeting() -> String {
        let h = Calendar.current.component(.hour, from: currentDate)
        switch h {
        case 5..<12:   return "Good Morning"
        case 12..<17:  return "Good Afternoon"
        case 17..<22:  return "Good Evening"
        default:       return "Good Night"
        }
    }

    private func refreshCurrentDate() {
        currentDate = Date()
    }

    private func forecastLine() -> String {
        let t = Int(temperatureC)
        let rain = isRaining ? "Rain expected" : "Clear skies"
        return "It's \(t)°C with \(rain.lowercased())."
    }

    private func applyWeatherSnapshot() {
        if let t = weather.currentTempC { temperatureC = t }
        isRaining = weather.isRainingNow
        forecastStatus = forecastLine()
    }

    private func refreshSuggestion() {
        let available = availableGarments
        
        guard !available.isEmpty else {
            suggested = []
            shownCandidates = []
            setFeedback("No garments available. Add some items to your wardrobe.")
            return
        }
        
        // Track candidates for negative sampling
        shownCandidates = available
        
        let ctx = currentContext()

        let primary = OutfitComposer.suggestOutfit(
            from: available,
            ctx: ctx,
            modelContext: context,
            locked: locked,
            minDaysSinceWorn: 2
        )
        if !primary.isEmpty {
            suggested = primary
            return
        }

        let fallback = OutfitRecommender().suggest(
            from: available,
            desiredFormality: Int(desiredFormality),
            weather: .init(temperatureC: temperatureC, isRaining: isRaining)
        )
        if !fallback.isEmpty {
            suggested = fallback
            return
        }

        suggested = AIRecommender.shared.suggest(
            from: available,
            k: min(4, available.count),
            ctx: ctx,
            modelContext: context
        )
    }

    private func markAsWornAndSave() {
        saveCurrentOutfit(markAsWorn: true, isFavorite: false, rating: Int(userRating), reward: 0.8)
        refreshSuggestion()
    }

    private func likeCurrentOutfit() {
        saveCurrentOutfit(markAsWorn: true, isFavorite: true, rating: max(Int(userRating), 5), reward: 1.2)
        refreshSuggestion()
    }

    private func saveForLater() {
        saveCurrentOutfit(markAsWorn: false, isFavorite: false, rating: nil, reward: 0.2)
        refreshSuggestion()
    }

    private func banCurrentOutfit() {
        guard !suggested.isEmpty else { return }
        let key = outfitKey(for: suggested)
        context.insert(DismissedOutfit(key: key))
        AIRecommender.shared.learn(
            from: suggested,
            shown: shownCandidates,
            ctx: .init(desiredFormality: Int(desiredFormality),
                       temperatureC: temperatureC,
                       isRaining: isRaining,
                       now: .now),
            reward: 0.0,
            modelContext: context
        )
        try? context.save()
        refreshSuggestion()
    }

    private func saveCurrentOutfit(markAsWorn: Bool, isFavorite: Bool, rating: Int?, reward: Double) {
        guard !suggested.isEmpty else { return }
        let now = Date()

        let outfit = Outfit(date: now, itemIDs: suggested.map(\.id), rating: rating, isFavorite: isFavorite)
        if let profile = currentUserProfile() {
            outfit.ownerID = profile.id
            if !profile.outfitIDs.contains(outfit.id) {
                profile.outfitIDs.append(outfit.id)
            }
        }
        context.insert(outfit)

        for g in suggested where !g.outfitIDs.contains(outfit.id) {
            g.outfitIDs.append(outfit.id)
        }

        if markAsWorn {
            WearHistoryService.recordWorn(
                date: now,
                garmentIDs: suggested.map(\.id),
                source: .manual,
                context: context,
                outfitID: outfit.id,
                incrementTimesWorn: true,
                loveScoreDelta: nil
            )
        }

        if isFavorite {
            for g in suggested {
                g.isFavorite = true
                g.loveScore = min(100, g.loveScore + 10)
            }
        }

        AIRecommender.shared.learn(
            from: suggested,
            shown: shownCandidates,
            ctx: currentContext(now: now),
            reward: reward,
            modelContext: context
        )

        do {
            try context.save()
            let action: String
            if isFavorite { action = "Saved as Favorite" }
            else if markAsWorn { action = "Marked as Worn" }
            else { action = "Saved for Later" }
            setFeedback(action)
        } catch {
            setFeedback("Save failed: \(error.localizedDescription)")
        }
    }

    private func currentContext(now: Date = .now) -> RecoContext {
        RecoContext(
            desiredFormality: Int(desiredFormality),
            temperatureC: temperatureC,
            isRaining: isRaining,
            now: now
        )
    }

    private func setFeedback(_ message: String) {
        feedbackMessage = message
        showFeedback = true
    }

    private func currentUserProfile() -> UserProfile? {
        // MVP: Return first profile if any exists
        let desc = FetchDescriptor<UserProfile>()
        return (try? context.fetch(desc))?.first
    }
}

// --- Tiles ---

struct LockTile: View {
    let g: Garment
    let isLocked: Bool
    let isUnavailable: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
                            .blendMode(.plusLighter)
                    )
                if let img = g.resolvedImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else {
                    Image(systemName: "tshirt")
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                        .foregroundStyle(.secondary)
                }
                if isLocked {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.accentColor, Color.accentColor.opacity(0.6)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 3
                        )
                    Image(systemName: "lock.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(4)
                        .background(.ultraThinMaterial, in: Circle())
                        .offset(x: 28, y: -28)
                }
                if isUnavailable {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.black.opacity(0.4))
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 84, height: 84)
            .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
            Text(g.displayTitle)
                .font(.caption2)
                .lineLimit(1)
                .frame(width: 84)
                .foregroundStyle(.primary)
        }
    }
}

struct OutfitGrid: View {
    let items: [Garment]

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(items) { g in
                VStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                                .blendMode(.plusLighter)
                        )
                        .overlay {
                            if let img = g.resolvedImage {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFit()
                                    .padding(10)
                            } else {
                                Image(systemName: "tshirt")
                                    .resizable()
                                    .scaledToFit()
                                    .padding(16)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(height: 110)
                        .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 3)
                    Text(g.displayTitle)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                }
            }
        }
    }
}
