import Foundation
import SwiftData

enum BrandStore {
    static func normalizeBrandKey(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let allowed = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(allowed)).lowercased()
    }

    static func syncFromGarments(context: ModelContext) {
        let garments = (try? context.fetch(FetchDescriptor<Garment>())) ?? []
        let existing = (try? context.fetch(FetchDescriptor<Brand>())) ?? []
        let existingKeys = Set(existing.compactMap { $0.normalizedKey })

        let names = Set(garments.compactMap { $0.brand?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        )

        for name in names {
            let key = normalizeBrandKey(name)
            if !existingKeys.contains(key) {
                context.insert(Brand(name: name, normalizedKey: key))
            }
        }
        try? context.save()
    }

    static func upsert(name: String, context: ModelContext) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let existing = (try? context.fetch(FetchDescriptor<Brand>())) ?? []
        let key = normalizeBrandKey(trimmed)

        if let found = existing.first(where: { $0.normalizedKey == key || $0.name.lowercased() == trimmed.lowercased() }) {
            if found.normalizedKey == nil {
                found.normalizedKey = key
            }
            let preferredName = preferredDisplayName(current: found.name, candidate: trimmed)
            if preferredName != found.name {
                found.name = preferredName
            }
            try? context.save()
            return
        }

        context.insert(Brand(name: trimmed, normalizedKey: key))
        try? context.save()
    }

    static func mergeDuplicateBrands(context: ModelContext) {
        let brands = (try? context.fetch(FetchDescriptor<Brand>())) ?? []
        let garments = (try? context.fetch(FetchDescriptor<Garment>())) ?? []
        guard !brands.isEmpty else { return }

        var groups: [String: [Brand]] = [:]
        for brand in brands {
            let key = brand.normalizedKey ?? normalizeBrandKey(brand.name)
            brand.normalizedKey = key
            groups[key, default: []].append(brand)
        }

        for (key, group) in groups where group.count > 1 {
            let primaryName = group.map(\.name).reduce(group[0].name, preferredDisplayName)

            // Update garments to canonical display name
            for garment in garments {
                guard let brandName = garment.brand else { continue }
                if normalizeBrandKey(brandName) == key {
                    garment.brand = primaryName
                }
            }

            // Keep one brand, remove the rest
            if let primary = group.first(where: { $0.name == primaryName }) ?? group.first {
                primary.name = primaryName
                primary.normalizedKey = key
                for duplicate in group where duplicate.id != primary.id {
                    context.delete(duplicate)
                }
            }
        }

        try? context.save()
    }

    private static func preferredDisplayName(current: String, candidate: String) -> String {
        if current == candidate { return current }

        let currentHasUpper = current.rangeOfCharacter(from: .uppercaseLetters) != nil
        let candidateHasUpper = candidate.rangeOfCharacter(from: .uppercaseLetters) != nil
        let currentHasHyphen = current.contains("-")
        let candidateHasHyphen = candidate.contains("-")

        if candidateHasUpper && !currentHasUpper { return candidate }
        if candidateHasHyphen && !currentHasHyphen { return candidate }
        if candidate.count > current.count { return candidate }
        return current
    }
}
