import Foundation

/// Short or long sleeves on a top: what the "short with a jacket, or long?"
/// question and the user's learned comfort threshold act on.
enum SleeveLength: String, CaseIterable, Identifiable {
    case short
    case long

    var id: String { rawValue }

    var title: String {
        switch self {
        case .short: return String(localized: "sleeve_short")
        case .long: return String(localized: "sleeve_long")
        }
    }
}

extension Garment {
    /// The user's answer, else what the item type implies. nil for tops that
    /// come both ways (shirts, blouses) until the user says.
    var sleeveLength: SleeveLength? {
        get {
            guard category == .top else { return nil }
            if let raw = sleeveLengthRaw, let value = SleeveLength(rawValue: raw) { return value }
            switch itemType {
            case .tshirt?, .polo?, .tank?, .vest?: return .short
            case .sweater?, .hoodie?, .cardigan?: return .long
            default: return nil
            }
        }
        set { sleeveLengthRaw = newValue?.rawValue }
    }

    /// A top whose sleeve length is worth asking about once.
    var needsSleeveAnswer: Bool {
        category == .top && sleeveLength == nil
    }
}
