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

enum WidgetLookRole {
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

    /// Only today's looks get "I wore it"; tomorrow's can't be worn yet.
    var canConfirm: Bool { role != .tomorrow && look.isOpen }
}

enum WidgetLookPicker {
    static let eveningHour = 18

    /// Before the evening: today's look, then the evening look / tomorrow.
    /// From the evening: an open evening look, an open day look (so it can still be
    /// marked worn), then tomorrow. A look from another day is never shown as today's.
    static func choices(for snapshot: WidgetSnapshot?, at date: Date) -> [WidgetLookChoice] {
        guard let snapshot else { return [] }
        let calendar = Calendar.current
        let todayKey = DateFormatter.widgetDate.string(from: date)
        let tomorrowDate = calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
        let tomorrowKey = DateFormatter.widgetDate.string(from: tomorrowDate)

        let day = snapshot.look(date: todayKey, kind: WidgetLook.kindDay).map { WidgetLookChoice(look: $0, role: .today) }
        let evening = snapshot.look(date: todayKey, kind: WidgetLook.kindEvening).map { WidgetLookChoice(look: $0, role: .evening) }
        let tomorrow = snapshot.look(date: tomorrowKey, kind: WidgetLook.kindDay).map { WidgetLookChoice(look: $0, role: .tomorrow) }

        let ordered: [WidgetLookChoice?]
        if calendar.component(.hour, from: date) >= eveningHour {
            ordered = [
                evening?.look.isOpen == true ? evening : nil,
                day?.look.isOpen == true ? day : nil,
                tomorrow, day, evening
            ]
        } else {
            ordered = [day, evening, tomorrow]
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
        let choices = WidgetLookPicker.choices(for: entry.snapshot, at: entry.date)
        Group {
            if let primary = choices.first {
                switch family {
                case .systemMedium:
                    MediumLookView(choice: primary)
                case .systemLarge:
                    LargeLookView(choice: primary, next: choices.dropFirst().first, locationName: entry.snapshot?.locationName)
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

/// Small: the main piece large, two more beside it, ✓ in the corner.
private struct SmallLookView: View {
    let choice: WidgetLookChoice

    var body: some View {
        let items = LookItems(choice.look.items)
        VStack(alignment: .leading, spacing: 6) {
            LookHeader(choice: choice, compact: true)
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

/// Medium: the whole look as a flat-lay, with the why and the ✓ beside it.
private struct MediumLookView: View {
    let choice: WidgetLookChoice

    var body: some View {
        HStack(spacing: 12) {
            FlatLay(items: choice.look.items, maxCount: 4, sideWidth: 48)
            VStack(alignment: .leading, spacing: 4) {
                LookHeader(choice: choice, compact: false)
                if let reason = choice.look.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer(minLength: 0)
                StatusOrConfirm(choice: choice)
            }
            .frame(width: 118, alignment: .leading)
        }
    }
}

/// Large: the main look big, and the next one (evening or tomorrow) below.
private struct LargeLookView: View {
    let choice: WidgetLookChoice
    let next: WidgetLookChoice?
    let locationName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                LookHeader(choice: choice, compact: false)
                Spacer(minLength: 4)
                if let locationName {
                    Text(locationName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            FlatLay(items: choice.look.items, maxCount: 5, sideWidth: 72)
            HStack(alignment: .center, spacing: 8) {
                if let reason = choice.look.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                StatusOrConfirm(choice: choice)
            }
            if let next {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    LookHeader(choice: next, compact: true)
                    HStack(spacing: 4) {
                        ForEach(LookItems(next.look.items).all.prefix(5), id: \.slot) { item in
                            ThumbTile(item: item)
                        }
                    }
                    .frame(height: 64)
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

/// "Today · 14°–22° · ☂ 60%", plus a ✓ when already worn.
private struct LookHeader: View {
    let choice: WidgetLookChoice
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(choice.role.title)
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .lineLimit(1)
                if choice.look.isWorn {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .accessibilityLabel(Text("widget_status_worn"))
                }
                if compact {
                    Spacer(minLength: 2)
                    weather
                }
            }
            if !compact {
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

private struct StatusOrConfirm: View {
    let choice: WidgetLookChoice

    var body: some View {
        if choice.canConfirm {
            Button(intent: ConfirmWornIntent(dateString: choice.look.date, look: choice.look.kind)) {
                Label("widget_mark_worn", systemImage: "checkmark")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
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
