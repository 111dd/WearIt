//
//  MySizesView.swift
//  WearIt
//
//  "My sizes": the user's usual clothing sizes and optional body measurements.
//  Usual sizes pre-fill the size when adding an item; later they let the app
//  find items that are in stock in the user's size. Nothing here is required.
//

import SwiftUI
import SwiftData

struct MySizesView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var profile: UserProfile

    @Query private var garments: [Garment]

    @State private var height = ""
    @State private var chest = ""
    @State private var waist = ""
    @State private var hips = ""
    @State private var inseam = ""
    @State private var didLoad = false

    /// Categories with their own usual size (outerwear follows tops).
    private static let sizedCategories: [Category] = [.top, .bottom, .shoes]

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.lg) {
                clothingSection
                bodySection
                Text(String(localized: "my_sizes_footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Spacing.xs)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, DS.Spacing.sm)
            .padding(.bottom, DS.Spacing.lg)
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(String(localized: "my_sizes_title"))
        .minimalCollapsingNavBar()
        .onAppear(perform: load)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { save() }
        }
        .onDisappear(perform: save)
    }

    // MARK: - Clothing sizes

    private var clothingSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            DSSectionHeader(String(localized: "my_sizes_clothing"), icon: "tshirt")

            ForEach(Self.sizedCategories) { category in
                sizeRow(for: category)
                if category != Self.sizedCategories.last { Divider() }
            }
        }
        .dsCard()
    }

    private func sizeRow(for category: Category) -> some View {
        let learned = MySizesView.learnedSize(for: category, in: garments)
        return HStack(spacing: DS.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.sizeLabel(for: category))
                    .font(.subheadline)
                if profile.usualSize(for: category) == nil, let learned {
                    Text(String(format: NSLocalizedString("my_sizes_learned_format", comment: ""), learned.title))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Picker(Self.sizeLabel(for: category), selection: sizeBinding(for: category)) {
                Text(String(localized: "my_sizes_not_set")).tag(SizeOption?.none)
                ForEach(SizeOption.options(for: category)) { size in
                    Text(size.title).tag(SizeOption?.some(size))
                }
            }
            .pickerStyle(.menu)
        }
    }

    private func sizeBinding(for category: Category) -> Binding<SizeOption?> {
        Binding(
            get: { profile.usualSize(for: category) },
            set: { profile.setUsualSize($0, for: category) }
        )
    }

    private static func sizeLabel(for category: Category) -> String {
        switch category {
        case .top, .outer: return String(localized: "my_sizes_tops")
        case .bottom: return String(localized: "my_sizes_bottoms")
        case .shoes: return String(localized: "my_sizes_shoes")
        case .accessory: return category.title
        }
    }

    // MARK: - Body measurements

    private var bodySection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            DSSectionHeader(String(localized: "my_sizes_body"), icon: "ruler")

            measurementRow(String(localized: "my_sizes_height"), text: $height)
            Divider()
            measurementRow(String(localized: "my_sizes_chest"), text: $chest)
            Divider()
            measurementRow(String(localized: "my_sizes_waist"), text: $waist)
            Divider()
            measurementRow(String(localized: "my_sizes_hips"), text: $hips)
            Divider()
            measurementRow(String(localized: "my_sizes_inseam"), text: $inseam)
        }
        .dsCard()
    }

    private func measurementRow(_ title: String, text: Binding<String>) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Text(title)
                .font(.subheadline)
            Spacer()
            TextField("—", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 80)
            Text(String(localized: "my_sizes_cm"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Load / save

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        height = Self.format(profile.heightCm)
        chest = Self.format(profile.chestCm)
        waist = Self.format(profile.waistCm)
        hips = Self.format(profile.hipsCm)
        inseam = Self.format(profile.inseamCm)
    }

    /// One save when leaving: each save is a CloudKit push.
    private func save() {
        profile.heightCm = Self.parse(height)
        profile.chestCm = Self.parse(chest)
        profile.waistCm = Self.parse(waist)
        profile.hipsCm = Self.parse(hips)
        profile.inseamCm = Self.parse(inseam)
        if context.hasChanges { try? context.save() }
    }

    private static func format(_ value: Double?) -> String {
        guard let value else { return "" }
        return value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// Accepts "92", "92.5" and "92,5"; anything outside 20–250 cm is ignored.
    private static func parse(_ text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), (20...250).contains(value) else { return nil }
        return value
    }

    // MARK: - Shared helpers

    /// The size most of the user's items in a category carry (at least two agree).
    static func learnedSize(for category: Category, in garments: [Garment]) -> SizeOption? {
        let sameGroup: Set<Category> = (category == .top || category == .outer) ? [.top, .outer] : [category]
        let sizes = garments.filter { sameGroup.contains($0.category) }.compactMap(\.sizeOption)
        let counts = Dictionary(sizes.map { ($0, 1) }, uniquingKeysWith: +)
        guard let best = counts.max(by: { $0.value < $1.value }), best.value >= 2 else { return nil }
        return best.key
    }

    /// The size the user wears in a category: what they set, else what their items say.
    static func usualSize(for category: Category, profile: UserProfile?, garments: [Garment]) -> SizeOption? {
        guard category != .accessory else { return nil }
        return profile?.usualSize(for: category) ?? learnedSize(for: category, in: garments)
    }

    /// One line for the profile row, e.g. "M · 32 · EU 42 · 178 cm".
    static func summary(for profile: UserProfile) -> String? {
        var parts = sizedCategories.compactMap { profile.usualSize(for: $0)?.title }
        if let height = profile.heightCm {
            parts.append("\(format(height)) \(String(localized: "my_sizes_cm"))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
