import SwiftUI
import SwiftData

//
//  StyleSwipeView.swift
//  WearIt
//
//  Swipe through looks built from your own wardrobe: right = like, left = not
//  for me, up = love. Each swipe trains the look-level taste model, the
//  per-piece model and pair affinities. Saved once per deck, not per swipe.
//

struct StyleSwipeView: View {
    let deckSize: Int
    /// Called after the user finished (or left) the deck.
    var onFinish: (() -> Void)? = nil

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @EnvironmentObject private var auth: AuthManager

    @Query(sort: \Garment.createdAt, order: .reverse) private var garments: [Garment]
    @Query private var users: [UserProfile]

    @State private var deck: [StyleSwipeDeckBuilder.Card] = []
    @State private var index = 0
    @State private var drag: CGSize = .zero
    @State private var didLoad = false
    @State private var swipeContext: RecoContext?
    @State private var progress: Double = 0
    @State private var insights: [StyleInsights.Insight] = []
    @State private var hasUnsavedSwipes = false
    @State private var crossedThreshold = false

    private let horizontalThreshold: CGFloat = 110
    private let verticalThreshold: CGFloat = 120

    var body: some View {
        VStack(spacing: DS.Spacing.md) {
            topBar
            content
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.bottom, DS.Spacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Opaque, full-screen layer of its own: nothing behind it shows or takes taps.
        .background { backdrop.ignoresSafeArea() }
        .contentShape(Rectangle())
        .presentationBackground(Color(.systemBackground))
        .task { loadDeckIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { saveIfNeeded() }
        }
        .onDisappear { saveIfNeeded() }
    }

    /// A soft wash of the current look's colors over a solid base.
    private var backdrop: some View {
        let tint = currentCardTint
        return ZStack {
            Color(.systemBackground)
            RadialGradient(
                colors: [tint.opacity(0.28), tint.opacity(0.08), .clear],
                center: .top,
                startRadius: 40,
                endRadius: 620
            )
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: index)
    }

    private var currentCardTint: Color {
        guard index < deck.count else { return .accentColor }
        let colors = deck[index].garments.compactMap { $0.safeColorTags.first }
        let accent = colors.first { !ColorHarmony.info($0).isNeutral && $0 != .multicolor }
        return accent?.color ?? colors.first?.color ?? .accentColor
    }

    // MARK: - Header

    private var topBar: some View {
        HStack(spacing: DS.Spacing.sm) {
            progressHeader
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .liquidGlassCircle(interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(localized: "action_close")))
        }
        .padding(.top, DS.Spacing.xs)
    }

    private var progressHeader: some View {
        HStack(spacing: DS.Spacing.sm) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "sparkles")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 32, height: 32)
            .animation(reduceMotion ? nil : DS.Animation.standard, value: progress)

            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "style_swipe_title"))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(String(format: NSLocalizedString("style_swipe_progress_format", comment: ""), Int((progress * 100).rounded())))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            if !deck.isEmpty, index < deck.count {
                Text(String(format: NSLocalizedString("style_swipe_count_short_format", comment: ""), index + 1, deck.count))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !didLoad {
            Spacer()
            ProgressView()
            Spacer()
        } else if deck.isEmpty {
            emptyState
        } else if index >= deck.count {
            finishedView
        } else {
            cardStack
            actionButtons
            Text(String(localized: "style_swipe_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var cardStack: some View {
        ZStack {
            if index + 1 < deck.count {
                SwipeLookCard(card: deck[index + 1])
                    .environment(\.layoutDirection, layoutDirection)
                    .scaleEffect(0.94)
                    .offset(y: 14)
                    .opacity(0.6)
                    .allowsHitTesting(false)
            }
            let card = deck[index]
            SwipeLookCard(card: card)
                // Card text follows the app language; only the swipe is physical.
                .environment(\.layoutDirection, layoutDirection)
                .overlay(alignment: .topLeading) { verdictBadge(.pass) }
                .overlay(alignment: .topTrailing) { verdictBadge(.like) }
                .overlay(alignment: .bottom) { verdictBadge(.love) }
                .offset(drag)
                .rotationEffect(.degrees(Double(drag.width) / 18), anchor: .bottom)
                .gesture(dragGesture)
                .id(card.id)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(cardAccessibilityLabel(card)))
                .accessibilityAction(named: Text(String(localized: "style_swipe_like"))) { commit(.like) }
                .accessibilityAction(named: Text(String(localized: "style_swipe_pass"))) { commit(.pass) }
                .accessibilityAction(named: Text(String(localized: "style_swipe_love"))) { commit(.love) }
        }
        // Swipe directions are physical (right = like) in every language.
        .environment(\.layoutDirection, .leftToRight)
        .frame(maxHeight: .infinity)
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                drag = value.translation
                let crossed = pendingVerdict(for: value.translation) != nil
                if crossed != crossedThreshold {
                    crossedThreshold = crossed
                    if crossed { DS.haptic(0.4) }
                }
            }
            .onEnded { value in
                crossedThreshold = false
                if let verdict = pendingVerdict(for: value.translation) {
                    commit(verdict)
                } else {
                    withAnimation(reduceMotion ? nil : DS.Animation.standard) { drag = .zero }
                }
            }
    }

    private func pendingVerdict(for translation: CGSize) -> StyleSwipeDeckBuilder.Verdict? {
        if translation.height < -verticalThreshold, abs(translation.width) < horizontalThreshold {
            return .love
        }
        if translation.width > horizontalThreshold { return .like }
        if translation.width < -horizontalThreshold { return .pass }
        return nil
    }

    @ViewBuilder
    private func verdictBadge(_ verdict: StyleSwipeDeckBuilder.Verdict) -> some View {
        let strength: Double = {
            switch verdict {
            case .like: return Double(max(0, drag.width) / horizontalThreshold)
            case .pass: return Double(max(0, -drag.width) / horizontalThreshold)
            case .love: return Double(max(0, -drag.height) / verticalThreshold)
            }
        }()
        Label(verdictTitle(verdict), systemImage: verdictIcon(verdict))
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .background(verdictColor(verdict), in: Capsule())
            .padding(DS.Spacing.md)
            .opacity(min(1, strength))
            .accessibilityHidden(true)
    }

    private var actionButtons: some View {
        HStack(spacing: DS.Spacing.lg) {
            actionButton(.pass)
            actionButton(.love)
            actionButton(.like)
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private func actionButton(_ verdict: StyleSwipeDeckBuilder.Verdict) -> some View {
        Button {
            commit(verdict)
        } label: {
            Image(systemName: verdictIcon(verdict))
                .font(.title2.weight(.semibold))
                .foregroundStyle(verdictColor(verdict))
                .frame(width: verdict == .love ? 52 : 64, height: verdict == .love ? 52 : 64)
                .liquidGlassCircle(interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verdictTitle(verdict)))
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.sm) {
            Spacer()
            Image(systemName: "hanger")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(String(localized: "style_swipe_not_enough"))
                .font(.body)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var finishedView: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Spacer(minLength: 0)
            Text(String(localized: "style_swipe_done"))
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                DSSectionHeader(String(localized: "style_insight_title"), icon: "sparkles")
                if insights.isEmpty {
                    Text(String(localized: "style_insight_empty"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(insights, id: \.self) { insight in
                        Label(StyleInsights.text(insight), systemImage: StyleInsights.icon(insight))
                            .font(.body)
                            .foregroundStyle(.primary)
                    }
                }
            }
            .padding(DS.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassSurface(cornerRadius: DS.Radius.card, tint: Color(.systemBackground).opacity(0.35), castsShadow: true)

            Button {
                close()
            } label: {
                Text(String(localized: "action_done"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Spacing.sm)
            }
            .buttonStyle(.borderedProminent)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Actions

    private func loadDeckIfNeeded() {
        guard !didLoad else { return }
        defer { didLoad = true }
        let profile = CurrentUser.activeProfile(from: users, userIdentifier: auth.userIdentifier)
        let ctx = StyleSwipeDeckBuilder.neutralContext(profile: profile, garments: garments)
        swipeContext = ctx
        progress = AIRecommender.shared.learningProgress(profileID: ctx.profileID, modelContext: context)
        guard StyleSwipeDeckBuilder.isEligible(garments) else { return }

        var recent = FetchDescriptor<RecommendationEvent>(
            sortBy: [SortDescriptor(\RecommendationEvent.createdAt, order: .reverse)]
        )
        recent.fetchLimit = 400
        let events = (try? context.fetch(recent)) ?? []
        deck = StyleSwipeDeckBuilder.build(
            garments: garments,
            ctx: ctx,
            modelContext: context,
            size: deckSize,
            recentlySwiped: StyleSwipeDeckBuilder.recentlySwipedKeys(events)
        )
    }

    private func commit(_ verdict: StyleSwipeDeckBuilder.Verdict) {
        guard index < deck.count, let ctx = swipeContext else { return }
        let card = deck[index]
        StyleSwipeDeckBuilder.record(card, verdict: verdict, ctx: ctx, modelContext: context)
        hasUnsavedSwipes = true
        DS.haptic(verdict == .love ? 0.7 : 0.45)

        let exit: CGSize = {
            switch verdict {
            case .like: return CGSize(width: 600, height: drag.height)
            case .pass: return CGSize(width: -600, height: drag.height)
            case .love: return CGSize(width: drag.width, height: -900)
            }
        }()
        withAnimation(reduceMotion ? nil : .easeIn(duration: 0.22)) {
            drag = exit
        }
        let advance = {
            drag = .zero
            index += 1
            progress = AIRecommender.shared.learningProgress(profileID: ctx.profileID, modelContext: context)
            if index >= deck.count {
                finishDeck()
            }
        }
        if reduceMotion {
            advance()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { advance() }
        }
    }

    private func finishDeck() {
        saveIfNeeded()
        StyleSwipeSchedule.markCompleted(deckSize: deckSize)
        if let ctx = swipeContext {
            let state = AIRecommender.shared.ensureState(context: context, profileID: ctx.profileID)
            insights = StyleInsights.insights(from: state)
        }
    }

    private func saveIfNeeded() {
        guard hasUnsavedSwipes else { return }
        hasUnsavedSwipes = false
        try? context.save()
    }

    private func close() {
        saveIfNeeded()
        onFinish?()
        dismiss()
    }

    // MARK: - Labels

    private func verdictTitle(_ verdict: StyleSwipeDeckBuilder.Verdict) -> String {
        switch verdict {
        case .like: return String(localized: "style_swipe_like")
        case .pass: return String(localized: "style_swipe_pass")
        case .love: return String(localized: "style_swipe_love")
        }
    }

    private func verdictIcon(_ verdict: StyleSwipeDeckBuilder.Verdict) -> String {
        switch verdict {
        case .like: return "heart.fill"
        case .pass: return "xmark"
        case .love: return "star.fill"
        }
    }

    private func verdictColor(_ verdict: StyleSwipeDeckBuilder.Verdict) -> Color {
        switch verdict {
        case .like: return .green
        case .pass: return .red
        case .love: return .orange
        }
    }

    private func cardAccessibilityLabel(_ card: StyleSwipeDeckBuilder.Card) -> String {
        let titles = card.garments.map(\.displayTitle).joined(separator: ", ")
        return String(format: NSLocalizedString("style_swipe_card_a11y_format", comment: ""), titles)
    }
}

// MARK: - Schedule

/// When to offer Style Swipe: a longer first deck once, then a short one a day.
enum StyleSwipeSchedule {
    private static let onboardingDoneKey = "styleSwipe.onboardingDone"
    private static let lastDailyKey = "styleSwipe.lastDailyDate"
    private static let dismissedKey = "styleSwipe.entryDismissedDate"

    static var needsOnboarding: Bool {
        !UserDefaults.standard.bool(forKey: onboardingDoneKey)
    }

    static var nextDeckSize: Int {
        needsOnboarding ? StyleSwipeDeckBuilder.onboardingDeckSize : StyleSwipeDeckBuilder.dailyDeckSize
    }

    /// Show the planner entry card at most once a day, until done or dismissed.
    static func shouldOfferToday(now: Date = Date()) -> Bool {
        let calendar = Calendar.current
        if let last = UserDefaults.standard.object(forKey: lastDailyKey) as? Date,
           calendar.isDate(last, inSameDayAs: now) {
            return false
        }
        if let dismissed = UserDefaults.standard.object(forKey: dismissedKey) as? Date,
           calendar.isDate(dismissed, inSameDayAs: now) {
            return false
        }
        return true
    }

    static func markCompleted(deckSize: Int, now: Date = Date()) {
        if deckSize >= StyleSwipeDeckBuilder.onboardingDeckSize {
            UserDefaults.standard.set(true, forKey: onboardingDoneKey)
        }
        UserDefaults.standard.set(now, forKey: lastDailyKey)
    }

    static func dismissForToday(now: Date = Date()) {
        UserDefaults.standard.set(now, forKey: dismissedKey)
    }
}
