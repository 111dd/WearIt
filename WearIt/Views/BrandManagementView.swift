import SwiftUI
import SwiftData

struct BrandManagementView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Brand.name, order: .forward) private var brands: [Brand]
    @Query(sort: \Garment.createdAt, order: .reverse) private var garments: [Garment]

    @State private var editingBrand: Brand?
    @State private var editName: String = ""

    @State private var mergingBrand: Brand?
    @State private var mergeTarget: Brand?

    @State private var showAlert = false
    @State private var alertMessage = ""

    var body: some View {
        List {
            Section {
                Button {
                    BrandStore.mergeDuplicateBrands(context: context)
                    refreshBrandKeys()
                } label: {
                    Label(String(localized: "brand_merge_duplicates"), systemImage: "arrow.triangle.2.circlepath")
                }
            }

            Section {
                ForEach(brands) { brand in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(brand.name)
                                .font(.subheadline.weight(.semibold))

                            Text(String(format: NSLocalizedString("brand_items_count_format", comment: ""), brandUsageCount(brand)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Menu {
                            Button {
                                editName = brand.name
                                editingBrand = brand
                            } label: {
                                Label(String(localized: "action_rename"), systemImage: "pencil")
                            }

                            Button {
                                mergingBrand = brand
                                mergeTarget = nil
                            } label: {
                                Label(String(localized: "action_merge"), systemImage: "arrow.triangle.merge")
                            }

                            Button(role: .destructive) {
                                deleteBrandIfUnused(brand)
                            } label: {
                                Label(String(localized: "action_delete"), systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text(String(localized: "brand_list_title"))
            }
        }
        .navigationTitle(String(localized: "brand_management_title"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingBrand) { brand in
            NavigationStack {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Text(String(localized: "brand_rename_title"))
                        .font(.headline)

                    TextField(String(localized: "brand_name_placeholder"), text: $editName)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        renameBrand(brand, to: editName)
                        editingBrand = nil
                    } label: {
                        Text(String(localized: "action_save"))
                            .frame(maxWidth: .infinity)
                    }
                    .dsPrimaryButton()

                    Spacer()
                }
                .padding(DS.Spacing.md)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(String(localized: "action_close")) { editingBrand = nil }
                    }
                }
            }
        }
        .sheet(item: $mergingBrand) { brand in
            NavigationStack {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Text(String(localized: "brand_merge_title"))
                        .font(.headline)

                    Picker(String(localized: "brand_merge_target"), selection: $mergeTarget) {
                        ForEach(brands.filter { $0.id != brand.id }) { candidate in
                            Text(candidate.name).tag(Optional(candidate))
                        }
                    }
                    .pickerStyle(.wheel)

                    Button {
                        if let target = mergeTarget {
                            mergeBrand(brand, into: target)
                            mergingBrand = nil
                        } else {
                            alertMessage = String(localized: "brand_merge_select_target")
                            showAlert = true
                        }
                    } label: {
                        Text(String(localized: "action_merge"))
                            .frame(maxWidth: .infinity)
                    }
                    .dsPrimaryButton()

                    Spacer()
                }
                .padding(DS.Spacing.md)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(String(localized: "action_close")) { mergingBrand = nil }
                    }
                }
            }
        }
        .alert(String(localized: "error_title"), isPresented: $showAlert) {
            Button(String(localized: "action_close"), role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
    }

    private func brandUsageCount(_ brand: Brand) -> Int {
        garments.filter { BrandStore.normalizeBrandKey($0.brand ?? "") == BrandStore.normalizeBrandKey(brand.name) }.count
    }

    private func renameBrand(_ brand: Brand, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        brand.name = trimmed
        brand.normalizedKey = BrandStore.normalizeBrandKey(trimmed)
        // Update garments using old name
        for garment in garments where BrandStore.normalizeBrandKey(garment.brand ?? "") == brand.normalizedKey {
            garment.brand = trimmed
        }
        try? context.save()
        BrandStore.mergeDuplicateBrands(context: context)
    }

    private func mergeBrand(_ source: Brand, into target: Brand) {
        let targetName = target.name
        let targetKey = BrandStore.normalizeBrandKey(targetName)
        for garment in garments where BrandStore.normalizeBrandKey(garment.brand ?? "") == BrandStore.normalizeBrandKey(source.name) {
            garment.brand = targetName
        }
        context.delete(source)
        target.normalizedKey = targetKey
        try? context.save()
        BrandStore.mergeDuplicateBrands(context: context)
    }

    private func deleteBrandIfUnused(_ brand: Brand) {
        let usage = brandUsageCount(brand)
        guard usage == 0 else {
            alertMessage = String(localized: "brand_delete_in_use")
            showAlert = true
            return
        }
        context.delete(brand)
        try? context.save()
    }

    private func refreshBrandKeys() {
        for brand in brands where brand.normalizedKey == nil {
            brand.normalizedKey = BrandStore.normalizeBrandKey(brand.name)
        }
        try? context.save()
    }
}
