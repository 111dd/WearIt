# Planner UX and recommendation quality — 2026-10-22

Scope: first focused packet for Dor's requested visual/UX alternatives and smarter recommendations. Existing local shopping, photo and planner work is preserved. Nothing was built, tested, launched, committed or published by the agent.

## Implemented source changes

- `UI/OutfitLookRow.swift`: wear prompts and reaction controls fit horizontally when possible, then stack; accessibility text sizes use a two-column reaction grid. Confirm, not-worn, reactions, dismiss and capture targets have a minimum 44-point extent. Copy wraps instead of shrinking. VoiceOver exposes only currently available actions, including clearing a status; a compact summary offers no inactive replace action. Status bounce respects Reduce Motion.
- `Views/OutfitPlannerView.swift`: day/date headings and work/own-clothes choices stack at accessibility text sizes. Work choices, jacket actions and hint-dismiss controls have 44-point targets. The memoized card signature includes Dynamic Type so the selected layout updates. Existing worn-day collapse, independent evening look, footer Add, actions and deferred card type boundaries remain.
- `Logic/GarmentWeatherHistory.swift`: retain the direction of a thermal complaint. A too-warm sample at 24°C does not count against the item on an 18°C day, and a too-cold sample does not count against it on a warmer day. The existing six-degree locality, conservative confidence and weak wear evidence remain. Direction eligibility precedes exact-item/type fallback. Type samples stay one per day/look/type and are chosen deterministically, preferring the latest explicit response over wearing alone.
- `Views/OutfitPlannerView.swift`: new recommendation events refresh derived taste/comfort history. General feedback trains only the evaluated day look; freshly recalculated day/evening alternatives are no longer invented as rejected examples. Real explicit swap/preference learning remains. Historical weights are not reset or retroactively corrected. No feedback-triggered automatic replanning was added.
- `Logic/AIRecommender.swift`: alternative looks require two changed core pieces when at least two eligible core slots can vary. With exactly one variable slot, a one-piece alternative is allowed; an entirely fixed outfit is returned once. Candidate pools, score formulas, first choice, locked categories, targets, availability/weather gates and optional layers are preserved. Target filtering can still conservatively reduce the number of alternatives.
- `Services/AccountDataService.swift`: additive export schema 2 includes stored recommendation events, profile/garment/plan identity and the export time zone. Recommendation fetch failure throws instead of claiming there are zero events. No new stored model, remote service or upload was introduced.

## Design proposals and selected direction

Update 2026-10-24: Dor selected **היום במרכז**. The focused adaptive-photo/one-piece/multiple-accessory implementation and its pending device scenarios are recorded in `Adaptive-Looks-2026-10-24.md`. The prototypes below remain sample-data proposals rather than app screenshots or proof that every visual detail was implemented.

The conversation contains two interactive, Hebrew, sample-data proposals:

- **היום במרכז**: today's photograph row and a clearly named wear action lead the card, with a quieter alternate-look action, short expandable reasoning and the evening Add footer. Lowest departure from the current hierarchy.
- **יום וערב**: separate sun/moon sections and a day-to-evening rhythm, with a larger lead garment and smaller supporting items. Day completion collapses independently; evening remains available.

The prototypes can mark worn, reopen/collapse, undo, switch between two example looks, reveal reasoning and add/confirm evening. Optional host controls enlarge text or adjust spacing. Garments, events and weather are expressly examples; these are proposals, not screenshots or real recommendation results. The selected direction retains the Today-first hierarchy; its complete visual and runtime acceptance still requires Dor's device review.

The fragment was read as source and wrapped with the bundled renderer. Browser inspection of a local `file:` URL was denied by URL policy; no alternate-browser/protocol workaround was attempted. Visual layout and interactions have not been inspected in a running browser or app.

## Measuring outcomes

See `Recommendation-Quality-Guide-2026-10-22.md` and `Tools/recommendation_quality_report.py`. The local, read-only report consumes a fresh export and compares equal windows around the actual first device-use date of the change. It counts explicit comfort/style responses among responding looks and distinct garment wear-days/core items, with profile/legacy/unknown-category and partial-window coverage. It never reads photos, uploads data, replays current weights as historical predictions or labels observed counts as recommendation accuracy. The tool itself has received source review only and has not been executed.

## Owner-run acceptance scenarios

| Area | Scenario | Expected behavior |
| --- | --- | --- |
| Layout | Hebrew/English at normal and accessibility text sizes, narrow phone | Primary wear actions remain visible; labels wrap; reaction actions form a grid when needed; no manual double RTL reversal. |
| Worn state | Confirm today, reopen/collapse, undo; repeat via calendar/widget | Day collapses, work choice hides, evening stays independent; explicit calendar opening expands the requested look. |
| Accessibility | VoiceOver on compact/full/planned/not-worn rows; Reduce Motion | Available actions match state; collapsed replace is absent; status symbol does not bounce with Reduce Motion. |
| Thermal direction | Too warm at 24°C; compare queries at 18/24/30°C | The 18°C query receives no negative evidence from that sample; same/hotter eligible queries retain the existing locality/weighting. This does not invent a comfortable response. |
| Thermal direction | Too cold at 18°C; compare 12/18/24°C | No negative transfer from that sample to 24°C; same/colder eligible queries remain supported. |
| Evidence | One versus several distinct days, duplicate taps, generic love, mixed profiles | No duplicate-day evidence; generic love is not thermal evidence; existing profile rules and conservative confidence remain. |
| Taste | General love/worn/temperature response versus real item swap | Only evaluated pieces train from general feedback; unseen alternatives/day-evening pieces are not rejected. Explicit actual pairwise choices still train. |
| Freshness | Record a new comfort response, then explicitly request a new look | Derived history contains the new event. Worn/planned/locked looks do not change just because feedback arrived. |
| Variety | One top, one bottom, several eligible shoes; request multiple looks | Alternative shoes are available, with no duplicate outfit. With two variable core slots, keep the two-piece difference rule. With zero variable slots, return one fixed outfit. |
| Safety gates | Locked slot, only one suitable piece, unavailable item, weather/calendar target | Preserve the lock and suitability; never add an invalid piece to force variety. The first-ranked look is unchanged by the alternative-selection rule. |
| Export/report | Fresh schema 2 archive versus older export, incomplete after window | Report actual supported counts or unavailable/partial evidence explicitly; read no photos, print no personal names/notes/IDs. |

No improvement in measured speed, comfort, preference fit or recommendation acceptance is claimed. Broader background-scoring work, historical weight correction and a true suggestion-exposure denominator remain separate follow-ups.

## Source guidance

- [Apple accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [Apple button guidance](https://developer.apple.com/design/human-interface-guidelines/buttons)
- [Apple right-to-left guidance](https://developer.apple.com/design/human-interface-guidelines/right-to-left)
