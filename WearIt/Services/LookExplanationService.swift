//
//  LookExplanationService.swift
//  WearIt
//
//  On-device natural-language "why this look" explanations via Apple's
//  Foundation Models framework (iOS 26+). The recommender still picks the
//  garments; this service only explains the result after the fact.
//
//  Design constraints (deliberate):
//  - Deployment target is iOS 18.5, so everything touching FoundationModels
//    is gated behind @available(iOS 26, *) and runtime availability checks.
//  - A fresh LanguageModelSession per generation: sessions accumulate a
//    transcript, and one day's explanation must not leak into another's.
//  - Only Sendable snapshots cross into the actor — never SwiftData models
//    (Garment / DayPlan / ModelContext) and never raw calendar-event text.
//  - Generations are serialized (one at a time) and deduplicated per cache
//    key; cancellation propagates from the caller's .task(id:).
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Feature keys

enum LookExplanationKeys {
    /// AppStorage key for the user-facing toggle (default on).
    static let enabled = "aiLookExplanationsEnabled"
}

// MARK: - Request snapshot (Sendable, pure Foundation — unit-testable everywhere)

/// Everything the model needs, captured on the main actor as plain values.
struct LookExplanationRequest: Sendable, Equatable {
    struct GarmentInfo: Sendable, Equatable {
        let title: String
        let category: String
        let colors: [String]
        /// 1...5
        let warmth: Int
    }

    struct WeatherInfo: Sendable, Equatable {
        let morningTemp: Double
        let afternoonTemp: Double
        let eveningTemp: Double
        /// 0...1
        let rainProbability: Double
        /// English label, e.g. "sunny" — never a localized string.
        let condition: String
    }

    /// Bump to invalidate every cached explanation when the prompt changes.
    static let promptVersion = 1

    /// Start-of-day date the look is planned for.
    let date: Date
    /// LookTime.rawValue ("day" / "evening").
    let lookTime: String
    /// Stable identity of the outfit — used for the cache key, not the prompt.
    let garmentIDs: [String]
    let garments: [GarmentInfo]
    let weather: WeatherInfo?
    /// Structured CalendarOccasionKind.rawValue only. Raw event titles or
    /// people's names must never be put here.
    let occasion: String?
    /// Up to ~3 short taste facts, e.g. "often wears black".
    let tastePoints: [String]
    /// BCP-47 language code the answer should be written in, e.g. "en".
    let languageCode: String

    /// Deterministic key covering everything that influences the output.
    var cacheKey: String {
        let day = Int(date.timeIntervalSince1970 / 86_400)
        let weatherPart: String
        if let weather {
            weatherPart = [
                String(Int(weather.morningTemp.rounded())),
                String(Int(weather.afternoonTemp.rounded())),
                String(Int(weather.eveningTemp.rounded())),
                String(Int((weather.rainProbability * 10).rounded())),
                weather.condition
            ].joined(separator: ",")
        } else {
            weatherPart = "-"
        }
        return [
            "v\(Self.promptVersion)",
            String(day),
            lookTime,
            garmentIDs.sorted().joined(separator: ","),
            weatherPart,
            occasion ?? "-",
            tastePoints.joined(separator: ","),
            languageCode
        ].joined(separator: "#")
    }

    /// The user prompt sent to the model. Instructions live on the session.
    var prompt: String {
        var lines: [String] = []
        lines.append("Planned \(lookTime) outfit:")
        for garment in garments {
            var parts: [String] = [garment.title, "(\(garment.category)"]
            if !garment.colors.isEmpty {
                parts.append(", " + garment.colors.joined(separator: "/"))
            }
            parts.append(", warmth \(garment.warmth)/5)")
            lines.append("- " + parts.joined())
        }
        if let weather {
            lines.append(
                "Weather: \(weather.condition), morning \(Int(weather.morningTemp.rounded()))°C, "
                + "afternoon \(Int(weather.afternoonTemp.rounded()))°C, "
                + "evening \(Int(weather.eveningTemp.rounded()))°C, "
                + "rain chance \(Int((weather.rainProbability * 100).rounded()))%."
            )
        }
        if let occasion {
            lines.append("Occasion: \(occasion).")
        }
        if !tastePoints.isEmpty {
            lines.append("User taste: " + tastePoints.joined(separator: "; ") + ".")
        }
        lines.append("Explain briefly why this outfit works for the day.")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Garment naming request (Sendable, pure Foundation)

/// Structured garment facts for generating a clear, human-friendly name.
struct GarmentNameRequest: Sendable, Equatable {
    let category: String
    let itemType: String?
    let colors: [String]
    let material: String?
    let pattern: String?
    let fit: String?
    let brand: String?
    /// BCP-47 language code the name should be written in, e.g. "en".
    let languageCode: String

    /// The user prompt sent to the model.
    var prompt: String {
        var facts: [String] = ["category: \(category)"]
        if let itemType { facts.append("type: \(itemType)") }
        if !colors.isEmpty { facts.append("colors: " + colors.joined(separator: ", ")) }
        if let material { facts.append("material: \(material)") }
        if let pattern, pattern != "solid" { facts.append("pattern: \(pattern)") }
        if let fit, fit != "regular" { facts.append("fit: \(fit)") }
        if let brand, !brand.isEmpty { facts.append("brand: \(brand)") }
        return "Garment facts:\n" + facts.joined(separator: "\n") + "\nName this garment."
    }
}

// MARK: - Garment attribute enrichment (Sendable, pure Foundation)

/// Facts describing one garment, used to infer recommendation-critical
/// attributes (warmth, formality, season, style/occasion tags, material).
struct GarmentAttributesRequest: Sendable, Equatable {
    let category: String
    let itemType: String?
    let colors: [String]
    let pattern: String?
    let brand: String?

    var prompt: String {
        var facts: [String] = ["category: \(category)"]
        if let itemType { facts.append("type: \(itemType)") }
        if !colors.isEmpty { facts.append("colors: " + colors.joined(separator: ", ")) }
        if let pattern, pattern != "solid" { facts.append("pattern: \(pattern)") }
        if let brand, !brand.isEmpty { facts.append("brand: \(brand)") }
        return "Garment facts:\n" + facts.joined(separator: "\n")
            + "\nInfer this garment's wearing attributes."
    }
}

/// Typed, validated enrichment result. Invalid model output is dropped
/// field-by-field, never guessed.
struct GarmentAttributesResult: Sendable, Equatable {
    let warmth: Int?
    let formality: Int?
    let season: SeasonSuitability?
    let styleTags: [StyleTag]
    let occasionTags: [OccasionTag]
    let material: MaterialTag?
}

/// Plain result handed back to the UI.
struct LookExplanationResult: Sendable, Equatable {
    let summary: String
    let tip: String?

    /// Single display string for the planner preview line.
    var displayText: String {
        guard let tip, !tip.isEmpty else { return summary }
        return summary + " " + tip
    }
}

// MARK: - Availability

enum LookExplanationAvailability {
    /// True when the on-device model is usable for the current locale.
    /// Cheap enough to re-check before every generation, per Apple guidance —
    /// the model may still be downloading or Apple Intelligence may be off.
    static var isSupported: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let model = SystemLanguageModel.default
            guard model.isAvailable else { return false }
            guard let code = Locale.current.language.languageCode else { return false }
            return model.supportedLanguages.contains { $0.languageCode == code }
        }
        #endif
        return false
    }
}

// MARK: - Service

#if canImport(FoundationModels)

/// Structured model output. File-scope internal (not nested/private) because the
/// @Generable macro expansion needs the type visible at module level.
@available(iOS 26.0, *)
@Generable
struct GeneratedLookExplanation {
    @Guide(description: "One or two short sentences explaining why the outfit fits the day's weather, occasion and the user's taste.")
    let summary: String
    @Guide(description: "A short practical tip, only when genuinely useful (evening chill, rain, layering). Otherwise omit.")
    let tip: String?
}

@available(iOS 26.0, *)
@Generable
struct GeneratedGarmentName {
    @Guide(description: "A short, clear garment name of 2-4 words, like a product title in a wardrobe app. No trailing punctuation.")
    let name: String
}

@available(iOS 26.0, *)
@Generable
struct GeneratedLabelBrand {
    @Guide(description: "The brand name exactly as written on the label, or an empty string if none is clearly present.")
    let brand: String
}

@available(iOS 26.0, *)
@Generable
struct GeneratedGarmentAttributes {
    @Guide(description: "Warmth on a 1-5 scale: 1 = very light summer piece, 3 = mid-weight, 5 = heavy winter insulation.")
    let warmth: Int
    @Guide(description: "Formality on a 1-5 scale: 1 = gym/loungewear, 3 = everyday casual, 5 = black tie.")
    let formality: Int
    @Guide(description: "Best season fit. Exactly one of: summer, transitional, winter, allSeason.")
    let season: String
    @Guide(description: "Up to 2 style tags from: casual, smart_casual, business, formal, sporty, streetwear, bohemian, minimalist, vintage.")
    let styleTags: [String]
    @Guide(description: "Up to 2 occasion tags from: work, gym, dateNight, party, travel, beach, home. Empty if none clearly apply.")
    let occasionTags: [String]
    @Guide(description: "Most likely main material from: cotton, linen, wool, cashmere, silk, polyester, nylon, spandex, leather, suede, denim, fleece, velvet, corduroy. Omit if not reasonably inferable.")
    let material: String?
}

@available(iOS 26.0, *)
actor LookExplanationService {
    static let shared = LookExplanationService()

    private var cache: [String: LookExplanationResult] = [:]
    private var inFlight: [String: Task<LookExplanationResult?, Never>] = [:]
    /// Tail of the generation queue — serializes generations (one at a time).
    private var generationTail: Task<Void, Never>?
    private var didPrewarm = false

    private init() {}

    private static let instructionsText = """
    You are a friendly, concise personal stylist inside a wardrobe-planning app. \
    Explain in a warm, confident tone why the planned outfit works for the day. \
    Only mention garments from the provided list — never invent items, brands or colors. \
    The summary must be one or two short sentences. \
    Provide a tip only when it adds real practical value (evening temperature drop, \
    rain, a layer worth carrying); otherwise leave the tip empty. \
    Do not repeat the garment list verbatim; speak naturally.
    """

    /// Ask the system to load model resources ahead of the first generation.
    /// Call only once the planner is visible and there is a real look to explain.
    func prewarmIfNeeded() {
        guard !didPrewarm else { return }
        guard LookExplanationAvailability.isSupported else { return }
        didPrewarm = true
        let session = LanguageModelSession(instructions: Self.instructionsText)
        session.prewarm()
    }

    /// Returns a cached or freshly generated explanation, or nil when the
    /// model is unavailable, generation fails, or the task is cancelled.
    /// Safe to call repeatedly — deduplicated per cache key.
    func explanation(for request: LookExplanationRequest) async -> LookExplanationResult? {
        let key = request.cacheKey
        if let cached = cache[key] { return cached }
        if let existing = inFlight[key] {
            return await existing.value
        }
        guard LookExplanationAvailability.isSupported else { return nil }

        let previous = generationTail
        let task = Task<LookExplanationResult?, Never> {
            // FIFO: wait for the previous generation so we never run more
            // than one at a time (day 0 naturally goes first).
            await previous?.value
            return await Self.generate(request)
        }
        inFlight[key] = task
        generationTail = Task { _ = await task.value }

        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }

        inFlight[key] = nil
        if let result {
            cache[key] = result
        }
        return result
    }

    // MARK: Garment naming

    private static let namingInstructionsText = """
    You name garments for a personal wardrobe app. \
    Given structured facts about one garment, return a short, natural, specific name \
    of 2-4 words, like "White Linen Shirt" or "Slim Navy Chinos". \
    Use only the provided facts — never invent colors, brands or materials. \
    Mention the brand only if provided, at the end. \
    Use title case. No quotes, no trailing punctuation.
    """

    /// Generates a clear display name for a garment, or nil on any failure.
    /// One-shot (not cached): naming is explicit and user-triggered.
    func suggestGarmentName(for request: GarmentNameRequest) async -> String? {
        guard LookExplanationAvailability.isSupported else { return nil }
        do {
            let session = LanguageModelSession(instructions: Self.namingInstructionsText)
            let languageName = Locale(identifier: "en").localizedString(
                forLanguageCode: request.languageCode
            ) ?? "English"
            let prompt = request.prompt + "\nAnswer in \(languageName)."
            let response = try await session.respond(
                to: prompt,
                generating: GeneratedGarmentName.self
            )
            let name = response.content.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'."))
            guard !name.isEmpty, name.count <= 60 else { return nil }
            return name
        } catch {
            return nil
        }
    }

    // MARK: Care label brand extraction

    private static let labelBrandInstructionsText = """
    You read text scanned from clothing care labels. \
    Identify the brand name if one clearly appears in the text. \
    Care instructions, materials, sizes and country names are not brands. \
    If no brand is clearly present, return an empty string. Never guess.
    """

    /// Extracts a brand name from OCR'd care-label text, or nil when the
    /// model is unavailable or no brand is clearly present.
    func extractBrandFromLabel(text: String) async -> String? {
        guard LookExplanationAvailability.isSupported else { return nil }
        let trimmedInput = String(text.prefix(600))
        guard !trimmedInput.isEmpty else { return nil }
        do {
            let session = LanguageModelSession(instructions: Self.labelBrandInstructionsText)
            let response = try await session.respond(
                to: "Label text:\n\(trimmedInput)",
                generating: GeneratedLabelBrand.self
            )
            let brand = response.content.brand
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'."))
            guard !brand.isEmpty, brand.count <= 40 else { return nil }
            return brand
        } catch {
            return nil
        }
    }

    // MARK: Garment attribute enrichment

    private static let attributesInstructionsText = """
    You are a clothing expert tagging garments for a wardrobe app. \
    Given structured facts about one garment, infer its practical wearing attributes. \
    Base every answer only on the provided facts and common knowledge about that \
    garment type; when unsure about the material, omit it. \
    Use only the exact allowed values listed for each field.
    """

    /// Infers recommendation-critical attributes for a garment.
    /// Output is validated field-by-field; anything invalid is dropped.
    func enrichAttributes(for request: GarmentAttributesRequest) async -> GarmentAttributesResult? {
        guard LookExplanationAvailability.isSupported else { return nil }
        do {
            let session = LanguageModelSession(instructions: Self.attributesInstructionsText)
            let response = try await session.respond(
                to: request.prompt,
                generating: GeneratedGarmentAttributes.self
            )
            let raw = response.content
            let warmth = (1...5).contains(raw.warmth) ? raw.warmth : nil
            let formality = (1...5).contains(raw.formality) ? raw.formality : nil
            return GarmentAttributesResult(
                warmth: warmth,
                formality: formality,
                season: SeasonSuitability(rawValue: raw.season),
                styleTags: raw.styleTags.compactMap(StyleTag.init(rawValue:)).prefix(2).map { $0 },
                occasionTags: raw.occasionTags.compactMap(OccasionTag.init(rawValue:)).prefix(2).map { $0 },
                material: raw.material.flatMap(MaterialTag.init(rawValue:))
            )
        } catch {
            return nil
        }
    }

    // MARK: Generation

    private static func generate(_ request: LookExplanationRequest) async -> LookExplanationResult? {
        guard !Task.isCancelled else { return nil }
        do {
            // Fresh session per generation: no transcript carry-over between days.
            let session = LanguageModelSession(instructions: instructionsText)
            let languageName = Locale(identifier: "en").localizedString(
                forLanguageCode: request.languageCode
            ) ?? "English"
            let prompt = request.prompt + "\nAnswer in \(languageName)."
            let response = try await session.respond(
                to: prompt,
                generating: GeneratedLookExplanation.self
            )
            let summary = response.content.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { return nil }
            let tip = response.content.tip?.trimmingCharacters(in: .whitespacesAndNewlines)
            return LookExplanationResult(
                summary: summary,
                tip: (tip?.isEmpty == false) ? tip : nil
            )
        } catch {
            // Guardrail refusals, model unload, cancellation — fall back silently.
            return nil
        }
    }
}

#endif
