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
    let snapshot: TodaySnapshot?
}

struct WearItProvider: TimelineProvider {
    func placeholder(in context: Context) -> WearItEntry {
        WearItEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (WearItEntry) -> Void) {
        let entry = WearItEntry(date: Date(), snapshot: WidgetSnapshotReader.loadSnapshot())
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WearItEntry>) -> Void) {
        let entry = WearItEntry(date: Date(), snapshot: WidgetSnapshotReader.loadSnapshot())
        let nextUpdate = Calendar.current.date(byAdding: .hour, value: 4, to: Date()) ?? Date().addingTimeInterval(4 * 3600)
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
}

struct WearItWidgetEntryView: View {
    let entry: WearItEntry

    var body: some View {
        if #available(iOSApplicationExtension 17.0, *) {
            content
                .containerBackground(.ultraThinMaterial, for: .widget)
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = entry.snapshot, !snapshot.items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(snapshot.locationName ?? String(localized: "location_unavailable"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let low = snapshot.lowTempC, let high = snapshot.highTempC {
                        Text("\(Int(low))°–\(Int(high))°")
                            .font(.caption2.weight(.semibold))
                    }
                }

                HStack(spacing: 6) {
                    ForEach(slotOrder, id: \.self) { slot in
                        if let file = snapshot.items.first(where: { $0.slot == slot })?.thumbFilename,
                           !file.isEmpty,
                           let img = WidgetSnapshotReader.image(for: file) {
                            img
                                .resizable()
                                .scaledToFill()
                                .frame(width: 34, height: 44)
                                .clipped()
                                .cornerRadius(8)
                        }
                    }
                }

                HStack(spacing: 6) {
                    Text(snapshot.confirmedWorn ? String(localized: "widget_confirmed") : String(localized: "widget_not_confirmed"))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(snapshot.confirmedWorn ? Color.green.opacity(0.2) : Color.secondary.opacity(0.2), in: Capsule())
                    Spacer()
                    if !snapshot.confirmedWorn {
                        Button(intent: ConfirmWornIntent(dateString: snapshot.date)) {
                            Text(String(localized: "widget_mark_worn"))
                                .font(.caption2.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                Text(String(localized: "widget_open_planner"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .widgetURL(URL(string: "wearit://planner?day=today"))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "widget_empty_title"))
                    .font(.caption.weight(.semibold))
                Text(String(localized: "widget_empty_body"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .widgetURL(URL(string: "wearit://planner?day=today"))
        }
    }

    private var slotOrder: [String] {
        ["top", "bottom", "shoes", "outer", "accessory"]
    }
}

struct WearItWidget: Widget {
    let kind: String = "WearItWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WearItProvider()) { entry in
            WearItWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("WearIt – Daily Look")
        .description("See today’s outfit at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
