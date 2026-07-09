import AppIntents
import Foundation
import Observation

enum WearItIntentDestination: String, AppEnum, Sendable {
    case todayOutfit
    case addGarment

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Wear It destination")

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .todayOutfit: DisplayRepresentation(title: "Today's outfit", image: .init(systemName: "sparkles")),
        .addGarment: DisplayRepresentation(title: "Add garment", image: .init(systemName: "plus.circle"))
    ]
}

enum WearItIntentAction: String, Sendable {
    case refreshTodayOutfit
}

@MainActor
@Observable
final class WearItAppIntentRouter {
    static let shared = WearItAppIntentRouter()

    private static let destinationKey = "appIntentDestination"
    private static let actionKey = "appIntentAction"

    private(set) var pendingDestination: WearItIntentDestination?
    private(set) var pendingAction: WearItIntentAction?

    private var defaults: UserDefaults? {
        UserDefaults(suiteName: WidgetSnapshotService.appGroupID)
    }

    private init() {
        pendingDestination = Self.persistedDestination()
        pendingAction = Self.persistedAction()
    }

    func request(_ destination: WearItIntentDestination) {
        defaults?.set(destination.rawValue, forKey: Self.destinationKey)
        pendingDestination = destination
    }

    func consume() -> WearItIntentDestination? {
        let destination = pendingDestination ?? Self.persistedDestination()
        defaults?.removeObject(forKey: Self.destinationKey)
        pendingDestination = nil
        return destination
    }

    func request(_ action: WearItIntentAction) {
        defaults?.set(action.rawValue, forKey: Self.actionKey)
        pendingAction = action
    }

    func consumeAction() -> WearItIntentAction? {
        let action = pendingAction ?? Self.persistedAction()
        defaults?.removeObject(forKey: Self.actionKey)
        pendingAction = nil
        return action
    }

    private static func persistedDestination() -> WearItIntentDestination? {
        guard let rawValue = UserDefaults(suiteName: WidgetSnapshotService.appGroupID)?
            .string(forKey: destinationKey) else {
            return nil
        }

        return WearItIntentDestination(rawValue: rawValue)
    }

    private static func persistedAction() -> WearItIntentAction? {
        guard let rawValue = UserDefaults(suiteName: WidgetSnapshotService.appGroupID)?
            .string(forKey: actionKey) else {
            return nil
        }

        return WearItIntentAction(rawValue: rawValue)
    }
}

struct OpenWearItDestinationIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Wear It"
    static let description = IntentDescription("Opens Wear It at the requested destination.")
    static var openAppWhenRun: Bool { true }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Destination")
    var destination: WearItIntentDestination

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$destination) in Wear It")
    }

    init() {
        destination = .todayOutfit
    }

    init(destination: WearItIntentDestination) {
        self.destination = destination
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        WearItAppIntentRouter.shared.request(destination)
        return .result()
    }
}

struct ConfirmTodayOutfitIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Today's Outfit as Worn"
    static let description = IntentDescription("Marks today's planned outfit as worn in Wear It.")
    static var openAppWhenRun: Bool { true }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        WidgetCommandService.enqueueConfirmWorn(for: Date())
        WearItAppIntentRouter.shared.request(.todayOutfit)
        return .result(dialog: "Opening Wear It to mark today's outfit as worn.")
    }
}

struct ShowTodayOutfitIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Today's Outfit"
    static let description = IntentDescription("Reads today's planned outfit without opening Wear It.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let today = DateFormatter.widgetDate.string(from: Date())
        guard let snapshot = WidgetSnapshotService.loadSnapshot(),
              snapshot.date == today,
              !snapshot.items.isEmpty else {
            return .result(dialog: "No outfit is planned for today yet.")
        }

        let slotOrder = ["top", "bottom", "shoes", "outer", "accessory"]
        let titles = snapshot.items
            .sorted { lhs, rhs in
                (slotOrder.firstIndex(of: lhs.slot) ?? slotOrder.count)
                    < (slotOrder.firstIndex(of: rhs.slot) ?? slotOrder.count)
            }
            .map(\.title)
            .joined(separator: ", ")

        let format = NSLocalizedString("intent_today_outfit_summary_format", comment: "")
        let summary = String(format: format, titles)
        return .result(dialog: IntentDialog(stringLiteral: summary))
    }
}

struct RefreshTodayOutfitIntent: AppIntent {
    static let title: LocalizedStringResource = "Suggest Another Outfit"
    static let description = IntentDescription("Opens Wear It and creates another personalized outfit recommendation.")
    static var openAppWhenRun: Bool { true }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        WearItAppIntentRouter.shared.request(.refreshTodayOutfit)
        return .result(dialog: "Opening Wear It to suggest another outfit.")
    }
}

struct WearItAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenWearItDestinationIntent(destination: .todayOutfit),
            phrases: [
                "Open today's outfit in \(.applicationName)",
                "Show my outfit in \(.applicationName)"
            ],
            shortTitle: "Today's Outfit",
            systemImageName: "sparkles"
        )

        AppShortcut(
            intent: OpenWearItDestinationIntent(destination: .addGarment),
            phrases: [
                "Add a garment in \(.applicationName)",
                "Add clothes to \(.applicationName)"
            ],
            shortTitle: "Add Garment",
            systemImageName: "plus.circle"
        )

        AppShortcut(
            intent: ConfirmTodayOutfitIntent(),
            phrases: [
                "Mark today's outfit as worn in \(.applicationName)",
                "I wore my outfit in \(.applicationName)"
            ],
            shortTitle: "Mark Outfit Worn",
            systemImageName: "checkmark.circle"
        )

        AppShortcut(
            intent: ShowTodayOutfitIntent(),
            phrases: [
                "What's my outfit in \(.applicationName)",
                "Read today's outfit in \(.applicationName)"
            ],
            shortTitle: "Show Outfit",
            systemImageName: "text.bubble"
        )

        AppShortcut(
            intent: RefreshTodayOutfitIntent(),
            phrases: [
                "Suggest another outfit in \(.applicationName)",
                "Give me another outfit in \(.applicationName)"
            ],
            shortTitle: "New Suggestion",
            systemImageName: "wand.and.stars"
        )
    }
}
