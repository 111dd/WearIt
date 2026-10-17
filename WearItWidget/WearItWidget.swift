//
//  WearItWidget.swift
//  WearItWidget
//
//  Created by Dor David on 03/02/2026.
//

import WidgetKit
import SwiftUI
import AppIntents

struct WearItEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct WearItProvider: TimelineProvider {
    func placeholder(in context: Context) -> WearItEntry {
        WearItEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (WearItEntry) -> Void) {
        completion(WearItEntry(date: Date(), snapshot: WidgetSnapshotReader.loadSnapshot()))
    }

    /// The snapshot covers today and tomorrow, so the timeline switches by itself at
    /// the evening hour and at midnight (tomorrow's look becomes today's) without the app.
    func getTimeline(in context: Context, completion: @escaping (Timeline<WearItEntry>) -> Void) {
        let snapshot = WidgetSnapshotReader.loadSnapshot()
        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(86_400)
        let dayAfter = calendar.date(byAdding: .day, value: 1, to: tomorrow) ?? tomorrow.addingTimeInterval(86_400)

        var dates = [now]
        for day in [today, tomorrow] {
            if let evening = calendar.date(bySettingHour: WidgetLookPicker.eveningHour, minute: 0, second: 0, of: day),
               evening > now {
                dates.append(evening)
            }
        }
        dates.append(tomorrow)
        dates.sort()

        let entries = dates.map { WearItEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(dayAfter)))
    }
}

// MARK: - Which look to show

enum WidgetLookRole: String {
    case today, evening, tomorrow

    var title: String {
        switch self {
        case .today: return String(localized: "widget_role_today")
        case .evening: return String(localized: "widget_role_evening")
        case .tomorrow: return String(localized: "widget_role_tomorrow")
        }
    }
}

struct WidgetLookChoice {
    let look: WidgetLook
    let role: WidgetLookRole
    /// What the widget shows: the current look, or the one picked with ↻.
    let items: [WidgetLookItem]
    let optionCount: Int

    /// Only today's looks get "I wore it"; tomorrow's can't be worn yet.
    var canConfirm: Bool { role != .tomorrow && look.isOpen }
    /// ↻ for an open day look with ready alternatives.
    var canSwap: Bool { look.kind == WidgetLook.kindDay && look.isOpen && optionCount > 1 }
    /// "How was it?" once, right after today's day look is marked worn.
    var asksReaction: Bool { role == .today && look.isWorn && look.reaction == nil }
}

enum WidgetLookPicker {
    static let eveningHour = 18

    /// Before the evening: today's look, then the evening look / tomorrow.
    /// From the evening: an open evening look, an open day look (so it can still be
    /// marked worn), then tomorrow. A tab the user picked today goes first.
    /// A look from another day is never shown as today's.
    static func choices(for snapshot: WidgetSnapshot?, at date: Date, state: WidgetUIState, useTab: Bool) -> [WidgetLookChoice] {
        guard let snapshot else { return [] }
        let calendar = Calendar.current
        let todayKey = DateFormatter.widgetDate.string(from: date)
        let tomorrowDate = calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
        let tomorrowKey = DateFormatter.widgetDate.string(from: tomorrowDate)

        func choice(_ look: WidgetLook?, _ role: WidgetLookRole) -> WidgetLookChoice? {
            look.map {
                WidgetLookChoice(look: $0, role: role, items: $0.shownItems(in: state), optionCount: $0.allOptions.count)
            }
        }
        let day = choice(snapshot.look(date: todayKey, kind: WidgetLook.kindDay), .today)
        let evening = choice(snapshot.look(date: todayKey, kind: WidgetLook.kindEvening), .evening)
        let tomorrow = choice(snapshot.look(date: tomorrowKey, kind: WidgetLook.kindDay), .tomorrow)

        var ordered: [WidgetLookChoice?]
        if calendar.component(.hour, from: date) >= eveningHour {
            ordered = [
                evening?.look.isOpen == true ? evening : nil,
                day?.look.isOpen == true ? day : nil,
                tomorrow, day, evening
            ]
        } else {
            ordered = [day, evening, tomorrow]
        }
        if useTab, let tab = state.tab.flatMap(WidgetLookRole.init(rawValue:)) {
            ordered.insert([day, evening, tomorrow].compactMap { $0 }.first { $0.role == tab }, at: 0)
        }

        var result: [WidgetLookChoice] = []
        for choice in ordered.compactMap({ $0 })
        where !result.contains(where: { $0.look.date == choice.look.date && $0.look.kind == choice.look.kind }) {
            result.append(choice)
        }
        return result
    }
}

// MARK: - Views

struct WearItWidgetEntryView: View {
    let entry: WearItEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let state = WidgetUIState.load(today: DateFormatter.widgetDate.string(from: entry.date))
        let choices = WidgetLookPicker.choices(
            for: entry.snapshot,
            at: entry.date,
            state: state,
            useTab: family != .systemSmall
        )
        Group {
            if let primary = choices.first {
                switch family {
                case .systemMedium:
                    MediumLookView(choice: primary, all: choices)
                case .systemLarge:
                    LargeLookView(choice: primary, all: choices, locationName: entry.snapshot?.locationName)
                default:
                    SmallLookView(choice: primary)
                }
            } else {
                EmptyLookView()
            }
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(URL(string: "wearit://planner"))
    }
}

/// Small: the main piece large, two more beside it, ↻ and ✓ on the corners.
private struct SmallLookView: View {
    let choice: WidgetLookChoice

    var body: some View {
        let items = LookItems(choice.items)
        VStack(alignment: .leading, spacing: 6) {
            LookHeader(choice: choice, compact: true, showsTitle: true)
            HStack(spacing: 4) {
                ThumbTile(item: items.hero)
                if !items.rest.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(items.rest.prefix(2), id: \.slot) { item in
                            ThumbTile(item: item)
                        }
                    }
                    .frame(width: 44)
                }
            }
            .overlay(alignment: .topLeading) {
                SwapButton(choice: choice)
            }
            .overlay(alignment: .bottomTrailing) {
                if choice.canConfirm {
                    Button(intent: ConfirmWornIntent(dateString: choice.look.date, look: choice.look.kind)) {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel(Text("widget_mark_worn"))
                }
            }
        }
    }
}

/// Medium: tabs, the look as a flat-lay with ↻, and the why plus ✓ / ✕ or "how was it?".
private struct MediumLookView: View {
    let choice: WidgetLookChoice
    let all: [WidgetLookChoice]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LookTabs(all: all, selected: choice.role)
            HStack(spacing: 10) {
                FlatLay(items: choice.items, maxCount: 4, sideWidth: 46)
                    .overlay(alignment: .topLeading) { SwapButton(choice: choice) }
                VStack(alignment: .leading, spacing: 4) {
                    LookHeader(choice: choice, compact: false, showsTitle: all.count < 2)
                    if let reason = choice.look.reason, !reason.isEmpty, !choice.asksReaction {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(all.count < 2 ? 3 : 2)
                    }
                    Spacer(minLength: 0)
                    LookActions(choice: choice)
                }
                .frame(width: 122, alignment: .leading)
            }
        }
    }
}

/// Large: tabs, the main look big, and the next one (evening or tomorrow) below.
private struct LargeLookView: View {
    let choice: WidgetLookChoice
    let all: [WidgetLookChoice]
    let locationName: String?

    var body: some View {
        let next = all.dropFirst().first
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                if all.count > 1 {
                    LookTabs(all: all, selected: choice.role)
                } else {
                    LookHeader(choice: choice, compact: false, showsTitle: true)
                }
                Spacer(minLength: 4)
                if let locationName {
                    Text(locationName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if all.count > 1 {
                LookHeader(choice: choice, compact: false, showsTitle: false)
            }
            FlatLay(items: choice.items, maxCount: 5, sideWidth: 72)
                .overlay(alignment: .topLeading) { SwapButton(choice: choice) }
            HStack(alignment: .center, spacing: 8) {
                if let reason = choice.look.reason, !reason.isEmpty, !choice.asksReaction {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                LookActions(choice: choice)
            }
            if let next {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    LookHeader(choice: next, compact: true, showsTitle: true)
                    HStack(spacing: 4) {
                        ForEach(LookItems(next.items).all.prefix(5), id: \.slot) { item in
                            ThumbTile(item: item)
                        }
                    }
                    .frame(height: 56)
                }
            }
        }
    }
}

private struct EmptyLookView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "hanger")
                .font(.title3)
                .foregroundStyle(.tint)
            Spacer(minLength: 0)
            Text("widget_empty_title")
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Text("widget_empty_body")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - Pieces

/// Today / This evening / Tomorrow, only for looks that exist.
private struct LookTabs: View {
    let all: [WidgetLookChoice]
    let selected: WidgetLookRole

    var body: some View {
        let roles = [WidgetLookRole.today, .evening, .tomorrow].filter { role in all.contains { $0.role == role } }
        if roles.count > 1 {
            HStack(spacing: 4) {
                ForEach(roles, id: \.self) { role in
                    Button(intent: SelectLookTabIntent(role: role.rawValue)) {
                        Text(role.title)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .foregroundStyle(role == selected ? AnyShapeStyle(.background) : AnyShapeStyle(.secondary))
                            .background(
                                Capsule().fill(role == selected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.08)))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// ↻: the next ready look.
private struct SwapButton: View {
    let choice: WidgetLookChoice

    var body: some View {
        if choice.canSwap {
            Button(intent: NextLookIntent(dateString: choice.look.date, look: choice.look.kind)) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption2.weight(.bold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .tint(.primary)
            .padding(2)
            .accessibilityLabel(Text("widget_another_look"))
        }
    }
}

/// "Today · 14°–22° · ☂ 60%", plus a ✓ when already worn.
private struct LookHeader: View {
    let choice: WidgetLookChoice
    let compact: Bool
    let showsTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if showsTitle {
                    Text(choice.role.title)
                        .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                if choice.look.isWorn {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .accessibilityLabel(Text("widget_status_worn"))
                }
                if compact || !showsTitle {
                    if compact { Spacer(minLength: 2) }
                    weather
                }
            }
            if !compact && showsTitle {
                weather
            }
        }
    }

    @ViewBuilder
    private var weather: some View {
        let look = choice.look
        HStack(spacing: 4) {
            if let low = look.lowTempC, let high = look.highTempC {
                Text(verbatim: compact ? "\(Int(high.rounded()))°" : "\(Int(low.rounded()))°–\(Int(high.rounded()))°")
                    .monospacedDigit()
            }
            if let rain = look.rainChance, rain >= 0.35 {
                Label {
                    Text(verbatim: "\(Int((rain * 100).rounded()))%")
                } icon: {
                    Image(systemName: "umbrella.fill")
                }
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.tint)
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// ✓ / ✕ while open; "how was it?" 😍🥶🥵 right after wearing; then the status.
private struct LookActions: View {
    let choice: WidgetLookChoice

    var body: some View {
        if choice.canConfirm {
            HStack(spacing: 4) {
                Button(intent: ConfirmWornIntent(dateString: choice.look.date, look: choice.look.kind)) {
                    Label("widget_mark_worn", systemImage: "checkmark")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                Button(intent: NotWornIntent(dateString: choice.look.date, look: choice.look.kind)) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .tint(.secondary)
                .accessibilityLabel(Text("widget_not_worn"))
            }
        } else if choice.asksReaction {
            VStack(alignment: .leading, spacing: 2) {
                Text("widget_how_was_it")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 2) {
                    reaction("😍", WidgetCommand.feedbackLoved, label: "widget_reaction_loved")
                    reaction("🥶", WidgetCommand.feedbackTooCold, label: "widget_reaction_too_cold")
                    reaction("🥵", WidgetCommand.feedbackTooWarm, label: "widget_reaction_too_warm")
                }
            }
        } else if choice.look.isWorn {
            Label("widget_status_worn", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        } else if choice.look.isNotWorn {
            Text("widget_status_not_worn")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func reaction(_ emoji: String, _ value: String, label: LocalizedStringKey) -> some View {
        Button(intent: LookFeedbackIntent(dateString: choice.look.date, value: value)) {
            Text(verbatim: emoji)
                .font(.title3)
                .frame(width: 30, height: 28)
                .background(Circle().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// Items in flat-lay order: the top (or outer layer) as the main piece, then
/// bottom, shoes, the outer layer and accessories.
private struct LookItems {
    private static let order = ["top", "bottom", "shoes", "outer", "accessory"]
    let all: [WidgetLookItem]

    init(_ items: [WidgetLookItem]) {
        all = items.sorted {
            (Self.order.firstIndex(of: $0.slot) ?? Self.order.count) < (Self.order.firstIndex(of: $1.slot) ?? Self.order.count)
        }
    }

    var hero: WidgetLookItem? {
        all.first { $0.slot == "top" } ?? all.first { $0.slot == "outer" } ?? all.first
    }

    var rest: [WidgetLookItem] {
        guard let hero else { return [] }
        return all.filter { $0.garmentID != hero.garmentID || $0.slot != hero.slot }
    }
}

/// The main piece on the leading side, the others in narrow columns beside it.
private struct FlatLay: View {
    let items: [WidgetLookItem]
    let maxCount: Int
    let sideWidth: CGFloat

    var body: some View {
        let ordered = LookItems(items)
        let rest = Array(ordered.rest.prefix(max(0, maxCount - 1)))
        HStack(spacing: 4) {
            ThumbTile(item: ordered.hero)
            ForEach(Array(stride(from: 0, to: rest.count, by: 2)), id: \.self) { start in
                VStack(spacing: 4) {
                    ForEach(rest[start..<min(start + 2, rest.count)], id: \.slot) { item in
                        ThumbTile(item: item)
                    }
                }
                .frame(width: sideWidth)
            }
        }
    }
}

/// A garment on a soft tile. `.fullColor` keeps the clothes' real colors on a
/// tinted or clear Home Screen instead of turning them into one-color shapes.
private struct ThumbTile: View {
    let item: WidgetLookItem?
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(renderingMode == .fullColor ? Color.primary.opacity(0.06) : Color.white.opacity(0.12))
            if let item, let image = WidgetSnapshotReader.image(for: item.thumbFilename) {
                image
                    .resizable()
                    .widgetAccentedRenderingMode(.fullColor)
                    .scaledToFit()
                    .padding(4)
                    .accessibilityLabel(Text(verbatim: item.title))
            } else {
                Image(systemName: "tshirt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WearItWidget: Widget {
    let kind: String = "WearItWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WearItProvider()) { entry in
            WearItWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("widget_display_name")
        .description("widget_display_description")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
