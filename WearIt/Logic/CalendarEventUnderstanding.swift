import Foundation

/// Understands a calendar event's title (Hebrew, English or mixed) well enough
/// to know what to wear for it. Pure value logic, no EventKit, so it can be
/// unit-tested. Matching is word-based (not substring), strips Hebrew one-letter
/// prefixes (ו ה ב ל מ ש כ) and construct / plural endings, and weighs every
/// matching keyword instead of taking the first hit.
enum CalendarEventUnderstanding {
    /// What an event means for the outfit.
    enum Kind: String, CaseIterable, Codable {
        case none
        case work
        case sport
        case travel
        case outdoor
        /// Brunch, a birthday, drinks: becomes day or evening by start time.
        case social
        case formal
        case blackTie
        case mourning
        /// Day off, errands, the kids' activities, video calls: no dress impact.
        case personal

        var priority: Int {
            switch self {
            case .none, .personal: return 0
            case .work: return 1
            case .travel, .outdoor: return 2
            case .sport: return 3
            case .social: return 4
            case .mourning: return 6
            case .formal: return 7
            case .blackTie: return 8
            }
        }
    }

    struct EventInput: Equatable {
        var title: String
        var location: String = ""
        var notes: String = ""
        var calendarTitle: String = ""
    }

    // MARK: - Classify

    static let threshold = 0.6

    static func classify(_ input: EventInput) -> Kind {
        if let corrected = CalendarEventCorrections.kind(forTitle: input.title) {
            return corrected
        }
        var scores: [Kind: Double] = [:]
        let titleTokens = Words(input.title)
        for keyword in vocabulary where keyword.matches(titleTokens) {
            scores[keyword.kind, default: 0] += keyword.weight
        }

        // Location only hints where you'll be (gym, beach, airport).
        let locationTokens = Words(input.location)
        if !locationTokens.isEmpty {
            for keyword in vocabulary
            where locationKinds.contains(keyword.kind) && keyword.matches(locationTokens) {
                scores[keyword.kind, default: 0] += keyword.weight * 0.7
            }
        }

        // Notes are mostly invite boilerplate (Zoom links, agendas); only an explicit
        // dress code there counts.
        let noteTokens = Words(input.notes)
        if !noteTokens.isEmpty {
            for keyword in vocabulary where keyword.kind == .blackTie && keyword.matches(noteTokens) {
                scores[.blackTie, default: 0] += keyword.weight
            }
        }

        // An event in a work calendar leans toward work, but a clear title wins.
        let calendarTokens = Words(input.calendarTitle)
        let inWorkCalendar = workCalendarNames.contains(where: { $0.matches(calendarTokens) })
        if inWorkCalendar {
            scores[.work, default: 0] += 0.5
        }

        if scores[.personal, default: 0] >= threshold,
           scores[.personal, default: 0] >= (scores.filter { $0.key != .personal }.values.max() ?? 0) {
            return .personal
        }

        let best = scores
            .filter { $0.key != .personal && $0.value >= threshold }
            .max { lhs, rhs in
                lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key.priority < rhs.key.priority
            }
        if let best { return best.key }
        // An event in a work calendar with an unknown title is still work.
        return inWorkCalendar ? .work : .none
    }

    private static let locationKinds: Set<Kind> = [.sport, .outdoor, .travel]

    // MARK: - Text normalization

    private static let finalLetters: [Character: Character] = [
        "ך": "כ", "ם": "מ", "ן": "נ", "ף": "פ", "ץ": "צ"
    ]
    private static let hebrewPrefixes: Set<Character> = ["ו", "ה", "ב", "ל", "מ", "ש", "כ"]
    private static let hebrewSuffixes = ["יות", "ות", "ים", "ית", "ת", "ה", "י"]

    /// Lowercased words with Hebrew final letters normalized and quote marks
    /// (geresh, gershayim) removed, so נתב"ג, בראנץ' and 1:1 survive.
    static func tokens(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lowered = text.lowercased()
        lowered = lowered.replacingOccurrences(of: "1:1", with: " oneonone ")
        lowered = lowered.replacingOccurrences(of: "1on1", with: " oneonone ")
        var cleaned = ""
        cleaned.reserveCapacity(lowered.count)
        for character in lowered {
            if "'\"`’‘׳״".contains(character) { continue }
            if let mapped = finalLetters[character] {
                cleaned.append(mapped)
            } else if character.isLetter || character.isNumber {
                cleaned.append(character)
            } else {
                cleaned.append(" ")
            }
        }
        return cleaned.split(separator: " ").map(String.init)
    }

    private static func isHebrew(_ word: String) -> Bool {
        word.unicodeScalars.contains { (0x05D0...0x05EA).contains($0.value) }
    }

    /// The forms a written word can match: itself, without one or two Hebrew
    /// prefix letters, and each of those without a construct / plural ending.
    static func forms(of word: String, stemming: Bool = true) -> Set<String> {
        var bases: [String] = [word]
        if isHebrew(word) {
            var current = word
            for _ in 0..<2 {
                guard let first = current.first, hebrewPrefixes.contains(first), current.count - 1 >= 3 else { break }
                current = String(current.dropFirst())
                bases.append(current)
            }
        }
        var result = Set(bases)
        guard stemming else { return result }
        for base in bases {
            result.insert(stem(base))
        }
        return result
    }

    /// Hebrew: drop one construct / plural ending (פגישת, פגישות → פגיש).
    /// English: drop a plural s / es.
    static func stem(_ word: String) -> String {
        if isHebrew(word) {
            for suffix in hebrewSuffixes where word.hasSuffix(suffix) && word.count - suffix.count >= 3 {
                return String(word.dropLast(suffix.count))
            }
            return word
        }
        if word.count > 4, word.hasSuffix("es"), !word.hasSuffix("ses") {
            return String(word.dropLast(2))
        }
        if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") {
            return String(word.dropLast())
        }
        return word
    }

    /// A text split into words, with each word's matchable forms computed once.
    struct Words {
        let plain: [Set<String>]
        let stemmed: [Set<String>]
        var count: Int { plain.count }
        var isEmpty: Bool { plain.isEmpty }

        init(_ text: String) {
            let words = CalendarEventUnderstanding.tokens(text)
            plain = words.map { CalendarEventUnderstanding.forms(of: $0, stemming: false) }
            stemmed = words.map { CalendarEventUnderstanding.forms(of: $0) }
        }
    }

    // MARK: - Keywords

    struct Keyword {
        let kind: Kind
        let weight: Double
        /// Normalized words of the phrase.
        let words: [String]
        /// Stem of each word (unless `exact`).
        let stems: [String]
        let exact: Bool

        init(_ phrase: String, _ kind: Kind, weight: Double = 1, exact: Bool = false) {
            self.kind = kind
            self.weight = weight
            self.exact = exact
            let words = CalendarEventUnderstanding.tokens(phrase)
            self.words = words
            self.stems = words.map { CalendarEventUnderstanding.stem($0) }
        }

        func matches(_ text: Words) -> Bool {
            guard !words.isEmpty, text.count >= words.count else { return false }
            for start in 0...(text.count - words.count) {
                var all = true
                for offset in 0..<words.count where !matchesWord(in: text, at: start + offset, word: offset) {
                    all = false
                    break
                }
                if all { return true }
            }
            return false
        }

        private func matchesWord(in text: Words, at position: Int, word index: Int) -> Bool {
            if exact {
                // Allow Hebrew prefixes only (לשבעה), never a different ending.
                return text.plain[position].contains(words[index])
            }
            let forms = text.stemmed[position]
            return forms.contains(words[index]) || forms.contains(stems[index])
        }
    }

    private static let workCalendarNames: [Keyword] = [
        Keyword("work", .work), Keyword("עבודה", .work), Keyword("office", .work),
        Keyword("משרד", .work), Keyword("job", .work)
    ]

    // swiftlint:disable function_body_length
    static let vocabulary: [Keyword] = {
        var list: [Keyword] = []
        func add(_ kind: Kind, _ phrases: [String], weight: Double = 1, exact: Bool = false) {
            list += phrases.map { Keyword($0, kind, weight: weight, exact: exact) }
        }

        // Life events outweigh the party / dinner words they often come with.
        add(.blackTie, ["black tie", "white tie", "gala", "גאלה", "ערב גאלה", "tuxedo", "טוקסידו"], weight: 1.5)
        add(.blackTie, ["dress code", "קוד לבוש"], weight: 0.6)

        add(.formal, [
            "wedding", "חתונה", "חופה", "נישואין", "נישואים",
            "בר מצווה", "בת מצווה", "בר מצוה", "בת מצוה", "bar mitzvah", "bat mitzvah",
            "bar mitzva", "bat mitzva", "ברית", "בריתה", "ברית מילה", "bris", "brit",
            "חינה", "henna", "אירוסין", "engagement party", "שבע ברכות",
            "cocktail", "קוקטייל", "reception", "graduation", "טקס", "ceremony", "טקס סיום",
            "prom", "נשף", "premiere", "בכורה", "opera", "אופרה", "ballet", "בלט",
            "awards", "כנס חגיגי"
        ], weight: 1.5)

        add(.mourning, ["funeral", "הלוויה", "לוויה", "ניחום אבלים", "אזכרה", "memorial", "shiva", "יארצייט", "אבל"])
        add(.mourning, ["שבעה"], exact: true)

        add(.sport, [
            "gym", "workout", "work out", "morning run", "evening run", "long run", "running club", "run club",
            "jog", "jogging", "10k", "5k", "marathon", "strength training", "surf", "surfing", "weights",
            "yoga", "pilates", "spinning", "crossfit", "hiit", "swim", "swimming", "tennis", "padel",
            "basketball", "football", "soccer", "boxing", "kickboxing", "krav maga", "cycling", "bike ride",
            "climbing", "bouldering", "zumba", "trx", "barre", "fitness", "personal trainer", "spin class",
            "חדר כושר", "כושר", "אימון", "אימון כוח", "ריצה", "יוגה", "פילאטיס", "ספינינג", "קרוספיט",
            "ריצת בוקר", "גלישה", "שחייה", "שחיה", "טניס", "פאדל", "כדורסל", "כדורגל", "כדורעף", "אגרוף", "קיקבוקס", "קרב מגע",
            "רכיבה", "אופניים", "טיפוס", "בולדרינג", "זומבה", "התעמלות", "ספורט"
        ])
        add(.sport, ["מכון", "סטודיו", "מאמן"], weight: 0.6)
        add(.sport, ["run", "running", "training", "class", "שיעור"], weight: 0.5)

        add(.work, [
            "עבודה", "משמרת", "פגישה", "ישיבה", "ישיבת צוות", "ראיון", "ראיון עבודה", "מצגת",
            "הרצאה", "הדרכה", "סדנה", "כנס", "לקוח", "הנהלה", "דיון", "סקירה", "סטטוס", "דדליין",
            "meeting", "standup", "stand up", "sync", "oneonone", "one on one", "review",
            "interview", "client", "presentation", "demo", "workshop", "conference", "offsite",
            "all hands", "kickoff", "kick off", "shift", "pitch", "board meeting", "deadline",
            "quarterly", "retro", "onboarding", "lecture", "seminar"
        ])
        add(.work, ["work", "office", "team", "צוות", "משרד"], weight: 0.6)

        add(.personal, [
            "out of office", "ooo", "day off", "sick", "sick day", "pto", "holiday", "חג",
            "wfh", "work from home", "remote day", "יום חופש", "מחלה", "יום מחלה",
            "עבודה מהבית", "מהבית", "zoom", "זום", "google meet", "teams call",
            "dentist", "doctor", "רופא", "רופאת", "רופא שיניים", "מרפאה", "haircut", "מספרה",
            "vet", "וטרינר", "bank", "בנק", "post office", "דואר", "משרד הפנים", "parent teacher",
            "אסיפת הורים", "pick up", "drop off", "איסוף", "לאסוף", "להסיע", "הסעה",
            "dog walk", "walk the dog", "עם הכלב", "טיול שנתי", "groceries", "סופר", "קניות"
        ], weight: 1.5)
        // Exact so חופשה (a vacation) and תורה (Torah) don't match.
        add(.personal, ["חופש", "תור"], weight: 1.5, exact: true)

        add(.travel, ["flight", "airport", "טיסה", "נמל תעופה", "נתבג", "שדה תעופה", "vacation", "חופשה"], weight: 1.2)
        // Weaker than work words, so "meeting at the hotel" stays a meeting.
        add(.travel, [
            "train", "travel", "trip", "hotel", "airbnb", "check in", "road trip", "bus", "drive to",
            "רכבת", "נסיעה", "אוטובוס", "מלון", "צימר", "חול"
        ], weight: 0.8)
        add(.travel, ["טיול"], weight: 0.6)

        add(.outdoor, [
            "park", "beach", "hike", "hiking", "picnic", "camping", "bbq", "barbecue", "zoo", "festival",
            "pool", "outdoor", "outdoors", "safari", "stadium",
            "פארק", "חוף", "חוף הים", "יום ים", "טיול רגלי", "מסלול", "פיקניק", "קמפינג", "על האש",
            "מנגל", "מדורה", "גן חיות", "ספארי", "פסטיבל", "בריכה", "אצטדיון", "טבע"
        ])
        // "טיול רגלי" (a hike) should beat the travel meaning of "טיול".
        add(.outdoor, ["טיול רגלי", "טיול בטבע"], weight: 0.5)
        add(.outdoor, ["ים"], exact: true)

        add(.social, [
            "date night", "date with", "first date", "דייט", "drinks", "בירה",
            "concert", "הופעה", "show", "הצגה", "club", "מועדון", "birthday", "יום הולדת", "יומולדת",
            "brunch", "בראנץ", "lunch", "ארוחת צהריים", "celebration", "חגיגה", "baby shower",
            "ערב חברים", "ערב גיבוש", "גיבוש", "happy hour", "networking", "מסעדה", "restaurant",
            "סטנדאפ", "stand-up comedy", "comedy", "fireworks", "זיקוקים", "wine tasting", "טעימות יין",
            "הרמת כוסית", "תיאטרון", "theatre", "theater"
        ])
        // Stronger than a work calendar, so "Team dinner" keeps its evening look.
        add(.social, ["dinner", "ארוחת ערב", "party", "מסיבה"], weight: 1.2)
        // Watching a game is an evening out, not a workout.
        add(.social, [
            "football game", "basketball game", "soccer game", "game at", "watch", "watching",
            "משחק כדורגל", "משחק כדורסל", "צפייה", "צפייה במשחק"
        ], weight: 1.5)
        add(.social, ["movie", "cinema", "סרט", "בר", "bar", "wine", "יין", "tasting"], weight: 0.6)
        return list
    }()
    // swiftlint:enable function_body_length
}

// MARK: - User corrections

/// "This event is a workout": the user's correction for an event title, so
/// "פילאטיס עם רונית" is understood from the next time on. Local to the device.
enum CalendarEventCorrections {
    private static let key = "calendarEventCorrections"

    static func normalizedTitle(_ title: String) -> String {
        CalendarEventUnderstanding.tokens(title).joined(separator: " ")
    }

    static func kind(forTitle title: String) -> CalendarEventUnderstanding.Kind? {
        let normalized = normalizedTitle(title)
        guard !normalized.isEmpty,
              let raw = (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[normalized] else {
            return nil
        }
        return CalendarEventUnderstanding.Kind(rawValue: raw)
    }

    static func set(_ kind: CalendarEventUnderstanding.Kind?, forTitle title: String) {
        let normalized = normalizedTitle(title)
        guard !normalized.isEmpty else { return }
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        all[normalized] = kind?.rawValue
        UserDefaults.standard.set(all, forKey: key)
    }
}

// MARK: - Correction menu

extension CalendarEventUnderstanding.Kind {
    /// What the user can say an event is, from the planner's event line.
    static let correctionChoices: [CalendarEventUnderstanding.Kind] = [
        .sport, .work, .social, .formal, .outdoor, .travel, .personal
    ]

    var correctionTitle: String {
        switch self {
        case .sport: return String(localized: "calendar_kind_sport")
        case .work: return String(localized: "calendar_kind_work")
        case .social: return String(localized: "calendar_kind_social")
        case .formal, .blackTie: return String(localized: "calendar_kind_formal")
        case .outdoor: return String(localized: "calendar_kind_outdoor")
        case .travel: return String(localized: "calendar_kind_travel")
        case .mourning: return String(localized: "calendar_kind_mourning")
        case .personal, .none: return String(localized: "calendar_kind_none")
        }
    }

    var correctionIcon: String {
        switch self {
        case .sport: return "figure.run"
        case .work: return "briefcase"
        case .social: return "moon.stars"
        case .formal, .blackTie: return "heart.circle"
        case .outdoor: return "sun.max"
        case .travel: return "airplane"
        case .mourning: return "leaf"
        case .personal, .none: return "minus.circle"
        }
    }
}
