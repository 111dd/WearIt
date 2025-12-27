//
//  EditGarmentView.swift
//  WearIt
//
//  Created by Dor David on 05/09/2025.
//

import SwiftUI
import SwiftData
import PhotosUI

struct EditGarmentView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @Bindable var garment: Garment   // ← מחייב iOS 17/SwiftData

    @State private var pickerItem: PhotosPickerItem?
    @State private var showDeleteAlert = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("פרטים") {
                TextField("שם", text: $garment.name)
                TextField("מותג", text: Binding(
                    get: { garment.brand ?? "" },
                    set: { garment.brand = $0.isEmpty ? nil : $0 }
                ))
                Picker("קטגוריה", selection: $garment.category) {
                    ForEach(Category.allCases) { Text($0.title).tag($0) }
                }
                TextField("צבעים (מופרדים בפסיק)",
                          text: Binding(
                            get: { garment.colors.joined(separator: ", ") },
                            set: { garment.colors = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                          ))
            }

            Section("מאפיינים") {
                Stepper("חום: \(garment.warmth)", value: $garment.warmth, in: 0...5)
                Stepper("פורמליות: \(garment.formality)", value: $garment.formality, in: 1...5)
                HStack {
                    Text("אהבה: \(garment.loveScore)")
                    Slider(value: Binding(get: { Double(garment.loveScore) },
                                          set: { garment.loveScore = Int($0) }),
                           in: 0...100)
                }
                Toggle("מועדף", isOn: $garment.isFavorite)
                HStack {
                    Text("נלבש לאחרונה:")
                    Spacer()
                    Text(garment.lastWorn.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                        .foregroundStyle(.secondary)
                }
                Button("אפס תאריך ״נלבש״") { garment.lastWorn = nil }
            }

            Section("תמונה") {
                PhotosPicker("בחר/י תמונה", selection: $pickerItem, matching: .images)
                    .onChange(of: pickerItem) { _, new in
                        Task {
                            if let data = try? await new?.loadTransferable(type: Data.self) {
                                garment.imageData = data
                            }
                        }
                    }
                if let d = garment.imageData, let ui = UIImage(data: d) {
                    Image(uiImage: ui).resizable().scaledToFit().frame(height: 180)
                    Button("הסר תמונה") { garment.imageData = nil }
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button("שמור") { saveAndClose() }
                    .buttonStyle(.borderedProminent)
                Button("מחק פריט", role: .destructive) { showDeleteAlert = true }
            }
        }
        .navigationTitle("עריכת פריט")
        .alert("שגיאת שמירה", isPresented: Binding(get: { errorMessage != nil },
                                                  set: { if !$0 { errorMessage = nil } })) {
            Button("אוקיי", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .alert("למחוק את הפריט?", isPresented: $showDeleteAlert) {
            Button("בטל", role: .cancel) {}
            Button("מחק", role: .destructive) { deleteItem() }
        } message: { Text("הפעולה בלתי הפיכה") }
    }

    private func saveAndClose() {
        do {
            try context.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteItem() {
        context.delete(garment)
        do {
            try context.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
