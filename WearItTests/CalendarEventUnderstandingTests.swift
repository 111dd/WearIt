import Foundation
import Testing
@testable import WearIt

/// Real-world titles from the 2026-10-05 calendar audit (Hebrew, English, mixed).
struct CalendarEventUnderstandingTests {
    private typealias Kind = CalendarEventUnderstanding.Kind

    private func kind(_ title: String, calendar: String = "", location: String = "", notes: String = "") -> Kind {
        CalendarEventUnderstanding.classify(
            CalendarEventUnderstanding.EventInput(title: title, location: location, notes: notes, calendarTitle: calendar)
        )
    }

    @Test func workoutsInBothLanguages() {
        for title in ["Gym", "Pilates", "Morning run", "Yoga class", "לאימון", "באימון כוח", "פילאטיס", "ספינינג", "ריצה עם החבר'ה", "חדר כושר"] {
            #expect(kind(title) == .sport, "\(title)")
        }
    }

    @Test func workIncludingHebrewForms() {
        for title in ["Standup", "1:1 with Dana", "Client pitch", "פגישת צוות", "ישיבה עם ההנהלה", "משמרת ערב", "ראיונות", "יום עבודה"] {
            #expect(kind(title) == .work, "\(title)")
        }
        #expect(kind("Project X", calendar: "עבודה") == .work)
    }

    @Test func noSubstringFalsePositives() {
        #expect(kind("Brunch") == .social)            // not "run"
        #expect(kind("Network drinks") == .social)    // not "work"
        #expect(kind("שיעור עברית") == .none)          // not "ברית"
        #expect(kind("Run tests") == .none)
        #expect(kind("Call mom") == .none)
        #expect(kind("Due date") == .none)
        #expect(kind("שבע בבוקר") == .none)           // not "שבעה"
    }

    @Test func lifeEventsBeatPartyWords() {
        #expect(kind("חתונה של אבי") == .formal)
        #expect(kind("מסיבת אירוסין") == .formal)
        #expect(kind("Engagement party") == .formal)
        #expect(kind("עלייה לתורה - בר מצווה של איתי") == .formal)
        #expect(kind("gala dinner") == .blackTie)
        #expect(kind("שבעה אצל משפחת כהן") == .mourning)
    }

    @Test func eveningOutKeepsItsLookOverWork() {
        #expect(kind("Client dinner") == .social)
        #expect(kind("Team dinner", calendar: "Work") == .social)
        #expect(kind("ארוחת ערב עם לקוח") == .social)
    }

    @Test func errandsAndRemoteChangeNothing() {
        for title in ["Dentist", "Pick up Noa from swimming", "להסיע את איתי לכדורגל", "Post office", "Out of office", "זום עם המשפחה"] {
            #expect(kind(title) == .personal, "\(title)")
        }
    }

    @Test func travelAndOutdoors() {
        #expect(kind("Flight to London") == .travel)
        #expect(kind("טיסה לאתונה") == .travel)
        #expect(kind("חופשה באילת") == .travel)
        #expect(kind("טיול רגלי בנחל") == .outdoor)
        #expect(kind("ים עם הילדים") == .outdoor)
        #expect(kind("Meeting", location: "Hilton hotel") == .work)
    }

    @Test @MainActor func workoutAfterWorkIsAReminderNotTheLook() {
        let morning = Date(timeIntervalSince1970: 1_760_000_000)
        let evening = morning.addingTimeInterval(9 * 3600)
        let context = CalendarContextService.build(
            events: [
                CalendarDayEvent(title: "Standup", start: morning, isAllDay: false, kind: .work, isEvening: false),
                CalendarDayEvent(title: "Gym", start: evening, isAllDay: false, kind: .sport, isEvening: true)
            ],
            hebrew: nil
        )
        #expect(context.dayOccasion == .work)
        #expect(context.eveningOccasion == .none)
        #expect(context.suggestEveningLook == false)
        #expect(context.sportReminder?.title == "Gym")
        #expect(context.formalityBump(isEvening: false, workDressCode: .business) == 2)
        #expect(context.formalityBump(isEvening: false, workDressCode: .free) == 0)
        #expect(context.occasion(isEvening: false, workDressCode: .uniform) == .none)
    }

    @Test @MainActor func workoutAloneSetsTheDayLook() {
        let context = CalendarContextService.build(
            events: [CalendarDayEvent(title: "Morning run", start: Date(), isAllDay: false, kind: .sport, isEvening: false)],
            hebrew: nil
        )
        #expect(context.dayOccasion == .sport)
        #expect(context.sportReminder == nil)
    }
}
