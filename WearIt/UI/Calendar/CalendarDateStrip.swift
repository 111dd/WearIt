import SwiftUI

//
//  CalendarDateStrip.swift
//  WearIt
//
//  Time navigation for the calendar tab. Collapsed: a single week row so the
//  selected day's look stays above the fold. Expanded: a full month grid.
//  Both modes annotate days with the same indicator dots.
//

// MARK: - Day Indicators

struct CalendarDayIndicators: Equatable {
    var hasOutfit: Bool = false
    var wasWorn: Bool = false
    var hasPhotos: Bool = false

    var isEmpty: Bool { !hasOutfit && !wasWorn && !hasPhotos }
}

// MARK: - Date Strip

struct CalendarDateStrip: View {
    @Binding var selectedDate: Date
    @Binding var isExpanded: Bool
    /// Keys must be normalized to start-of-day.
    let indicators: [Date: CalendarDayIndicators]

    /// Start of the displayed week (collapsed) or month (expanded).
    @State private var anchor: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    private let calendar = Calendar.current
    private static let cellHeight: CGFloat = 50

    init(selectedDate: Binding<Date>, isExpanded: Binding<Bool>, indicators: [Date: CalendarDayIndicators]) {
        _selectedDate = selectedDate
        _isExpanded = isExpanded
        self.indicators = indicators
        let calendar = Calendar.current
        let start = isExpanded.wrappedValue
            ? calendar.dateInterval(of: .month, for: selectedDate.wrappedValue)?.start
            : calendar.dateInterval(of: .weekOfYear, for: selectedDate.wrappedValue)?.start
        _anchor = State(initialValue: start ?? selectedDate.wrappedValue)
    }

    var body: some View {
        VStack(spacing: DS.Spacing.xs) {
            header
            weekdayHeader
            if isExpanded {
                monthGrid
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                weekRow
                    .transition(.opacity)
            }
        }
        .padding(DS.Spacing.sm)
        .liquidGlassSurface(cornerRadius: DS.Radius.card, castsShadow: true)
        .gesture(periodSwipeGesture)
        .onChange(of: selectedDate) { _, newValue in
            snapAnchor(to: newValue)
        }
        .onChange(of: isExpanded) { _, _ in
            snapAnchor(to: selectedDate)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DS.Spacing.xs) {
            navButton(systemImage: "chevron.backward", direction: -1)

            Spacer(minLength: 0)

            Button {
                DS.haptic(0.3)
                withAnimation(reduceMotion ? nil : DS.Animation.standard) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: DS.Spacing.xxs) {
                    Text(periodTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(periodTitle)
            .accessibilityValue(String(localized: isExpanded ? "calendar_show_week" : "calendar_show_month"))
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            navButton(systemImage: "chevron.forward", direction: 1)
        }
    }

    private func navButton(systemImage: String, direction: Int) -> some View {
        Button {
            shiftPeriod(by: direction)
        } label: {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(navAccessibilityLabel(direction: direction))
    }

    private func navAccessibilityLabel(direction: Int) -> String {
        if isExpanded {
            return String(localized: direction < 0 ? "calendar_previous_month" : "calendar_next_month")
        }
        return String(localized: direction < 0 ? "calendar_previous_week" : "calendar_next_week")
    }

    /// Month + year. In week mode the week may straddle two months; the
    /// title follows the selected day when it is inside the visible week.
    private var periodTitle: String {
        let formatter = Self.periodTitleFormatter
        let reference: Date
        if isExpanded {
            reference = anchor
        } else if let interval = calendar.dateInterval(of: .weekOfYear, for: anchor),
                  interval.contains(selectedDate) {
            reference = selectedDate
        } else {
            reference = calendar.date(byAdding: .day, value: 3, to: anchor) ?? anchor
        }
        return formatter.string(from: reference)
    }

    // MARK: Weekday Row

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(orderedWeekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private var orderedWeekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    // MARK: Week Row

    private var weekRow: some View {
        HStack(spacing: 0) {
            ForEach(weekDays(), id: \.self) { day in
                dayCell(for: day)
            }
        }
        .animation(reduceMotion ? nil : DS.Animation.fast, value: anchor)
    }

    // MARK: Month Grid

    private var monthGrid: some View {
        let days = monthDays()
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
        return LazyVGrid(columns: columns, spacing: DS.Spacing.xxs) {
            ForEach(days.indices, id: \.self) { index in
                if let day = days[index] {
                    dayCell(for: day)
                } else {
                    Color.clear.frame(height: Self.cellHeight)
                }
            }
        }
        .animation(reduceMotion ? nil : DS.Animation.fast, value: anchor)
    }

    // MARK: Day Cell

    private func dayCell(for day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(day)
        let dayIndicators = indicators[day] ?? CalendarDayIndicators()

        return Button {
            DS.haptic(0.3)
            withAnimation(reduceMotion ? nil : DS.Animation.fast) {
                selectedDate = day
            }
        } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.subheadline.weight(isSelected || isToday ? .bold : .regular))
                    .foregroundStyle(numberColor(isSelected: isSelected, isToday: isToday))
                    .frame(width: 34, height: 34)
                    .background {
                        if isSelected {
                            Circle().fill(Color.accentColor)
                        } else if isToday {
                            Circle().strokeBorder(Color.accentColor, lineWidth: 1.5)
                        }
                    }

                indicatorDots(dayIndicators)
            }
            .frame(maxWidth: .infinity, minHeight: Self.cellHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: day, indicators: dayIndicators))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func numberColor(isSelected: Bool, isToday: Bool) -> Color {
        if isSelected { return DS.Accent.onFill }
        if isToday { return .accentColor }
        return .primary
    }

    private func indicatorDots(_ dayIndicators: CalendarDayIndicators) -> some View {
        HStack(spacing: 3) {
            if dayIndicators.wasWorn {
                indicatorDot(.green)
            } else if dayIndicators.hasOutfit {
                indicatorDot(.accentColor)
            }
            if dayIndicators.hasPhotos {
                indicatorDot(.purple)
            }
        }
        .frame(height: 5)
    }

    private func indicatorDot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
    }

    // MARK: Date Math

    private func snapAnchor(to date: Date) {
        let component: Calendar.Component = isExpanded ? .month : .weekOfYear
        guard let start = calendar.dateInterval(of: component, for: date)?.start, start != anchor else { return }
        withAnimation(reduceMotion ? nil : DS.Animation.fast) {
            anchor = start
        }
    }

    private func weekDays() -> [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: anchor) }
    }

    /// Cells for the displayed month: leading nils pad up to the first weekday.
    private func monthDays() -> [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: anchor),
              let dayCount = calendar.range(of: .day, in: .month, for: anchor)?.count else {
            return []
        }
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7

        var cells: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<dayCount {
            cells.append(calendar.date(byAdding: .day, value: offset, to: interval.start))
        }
        return cells
    }

    private func shiftPeriod(by value: Int) {
        let component: Calendar.Component = isExpanded ? .month : .weekOfYear
        guard let next = calendar.date(byAdding: component, value: value, to: anchor) else { return }
        DS.haptic(0.3)
        withAnimation(reduceMotion ? nil : DS.Animation.fast) {
            anchor = next
        }
    }

    /// UIKit pan rather than a `DragGesture`: the strip sits in a vertical
    /// scroll view, where a drag gesture competes with scrolling.
    private var periodSwipeGesture: HorizontalSwipeGesture {
        HorizontalSwipeGesture(
            onChanged: { _ in },
            onEnded: { travel, speed in
                let isFling = abs(travel) >= 24 && speed >= 700
                guard abs(travel) >= 56 || isFling else { return }
                let leftward = travel < 0
                let forward = layoutDirection == .rightToLeft ? !leftward : leftward
                shiftPeriod(by: forward ? 1 : -1)
            },
            onCancelled: {}
        )
    }

    // MARK: Accessibility

    /// Shared formatters: built per call these ran once per visible day
    /// (42 in month mode) on every redraw.
    private static let periodTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter
    }()

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        return formatter
    }()

    private func accessibilityLabel(for day: Date, indicators dayIndicators: CalendarDayIndicators) -> String {
        var parts = [Self.fullDateFormatter.string(from: day)]
        if dayIndicators.wasWorn {
            parts.append(String(localized: "a11y_day_worn"))
        } else if dayIndicators.hasOutfit {
            parts.append(String(localized: "a11y_day_has_outfit"))
        }
        if dayIndicators.hasPhotos {
            parts.append(String(localized: "a11y_day_has_photos"))
        }
        return parts.joined(separator: ", ")
    }
}
