# Learnings

Newest first. Written by agents, for agents. Keep each entry short.

## 2026-09-16 — Skip full-table startup migrations

- **Did:** `DataMigrationService` now gates critical garment/brand work with UserDefaults (`criticalGarmentMigrationVersion`, `brandDuplicateMergeDone`). Pending garments are fetched by `migrationVersion` (`nil` / `0` / `1`) instead of `FetchDescriptor<Garment>()`. Thumbnail backfill uses `#Predicate { thumbnailPath == nil && imagePath != nil }`, generates thumbs off-main, and yields every 8 items. `BrandStore.mergeDuplicateBrands` loads garments only when duplicates exist.
- **Why:** Every launch was scanning the whole wardrobe (and dirtying brand `normalizedKey`) before the first UI frame.
- **Watch:** Bump `currentCriticalGarmentMigrationVersion` when `Garment.migrateIfNeeded()` writes a new version. SwiftData `#Predicate` cannot portably express `optionalInt < 2`. Do not reintroduce an unfiltered garment fetch on the critical path.

## 2026-09-15 — Calendar is a day journal, not a history dump

- **Did:** Replaced month-grid + summary + photos + history with `CalendarDateStrip` (week/month), `DayJournalCard`, and `DayLookEditorSheet`. Planner deep link via `Notification.Name.openPlannerDay`.
- **Why:** The old page stacked too many sections; calendar edits also diverged from planner storage.
- **Watch:** Write looks with `DayPlan.setSlotAssignments`, not only `selectedGarmentIDs`. Wear status goes through `applyDayLookWearStatus`. Reflection UI must `ViewThatFits` on small screens.

## 2026-09-15 — Replace-look ping-ponged two shirts

- **Did:** Session `replacementRotation` cycles candidates. Shoes / outer / accessory have `cooldownDays == 0` and a soft cross-day penalty instead of a hard exclude.
- **Why:** “Forgotten clothes” existed but replace only flipped between two tops; day-after-day shoes/coats are normal.
- **Watch:** Hard-excluding flexible categories will recreate the loop. Keep rotation per slot/day.

## 2026-09-15 — Secrets and App Store version mismatch

- **Did:** Barcode API key moved to `Config/Secrets.xcconfig` (`$(BARCODE_LOOKUP_API_KEY)` in Info.plist). Widget `MARKETING_VERSION` aligned to `1.0.1`. Added `.gitignore` for DerivedData / xcuserdata / secrets.
- **Why:** Hardcoded key in the repo; widget vs app version would fail App Store submit.
- **Watch:** Never commit `Config/Secrets.xcconfig`. Never put a real key in `BarcodeLookupService`.

## 2026-09-15 — Do not run build or simulator

- **Did:** Standing rule. User builds and runs in Xcode.
- **Why:** Agent `xcodebuild` with `CODE_SIGNING_ALLOWED=NO` stripped CloudKit entitlements (`SIGABRT`). `simctl launch` also killed LLDB (“Xcode has killed the LLDB RPC server”).
- **Watch:** Do not “just quickly compile to verify.” If you need confidence, reason about the change; the user will build.

## Still open (perf, not done)

- `Garment.imageData` (legacy blob) is still on the model — every garment fetch can pull it.
- `WearEventStore.events(on:)` / `findEvent` fetch all wear events then filter in memory; planner `isConfirmed` calls this from card signatures.
- Planner/wardrobe `@Query` often has no predicate/`fetchLimit`.
- Linear `allGarments.first { $0.id == id }` in planner — prefer `garmentsByID`.
- Do not measure by launching Instruments yourself; leave that to the user.
