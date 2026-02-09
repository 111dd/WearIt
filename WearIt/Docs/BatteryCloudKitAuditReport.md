# Battery + CloudKit Sync Audit Report (WearIt)

## 1. Suspected battery drains and causes

### High impact

| Hot spot | Why it drains battery |
|----------|------------------------|
| **Planner: `persistDayPlan` on every action** | Each drag, drop, assign, remove, lock, refresh calls `persistDayPlan` → `context.save()`. SwiftData + CloudKit sync on every save, so rapid UI actions (e.g. multiple drags) cause many local writes and CloudKit pushes. |
| **ProfileView: save on every toggle/time change** | Notification preference bindings call `try? context.save()` in the setter. Changing hour/minute or toggling multiple switches triggers a save (and thus CloudKit sync) per change. `scheduleNotifications()` is also invoked from 6× `.onChange(of: prefs.*)` with no debounce, so one pref change can trigger multiple schedules. |
| **Planner: `handleGarmentChange` → full regen** | `.onChange(of: allGarments.count)` runs `hydrateFromPlans()`, `updateAvailableGarments()`, and `generateAllOutfits()`. A single save elsewhere can change `@Query` → count change → heavy work on main thread. Cascades possible. |
| **WardrobeView: `rebuildVisibleGarments` on every filter change** | Six `.onChange` handlers (category, seasons, sort, temp, count, weather) each call `rebuildVisibleGarments()` (filter + sort). Rapid filter toggling causes repeated sorting/filtering on main thread. |

### Medium impact

| Hot spot | Why it drains battery |
|----------|------------------------|
| **BootstrapView: repeating Timer (2s)** | `Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true)` runs until view disappears. If loading is slow or user leaves app on loading, timer keeps firing. |
| **OutfitView: multiple `.onChange` → `refreshSuggestion()`** | Several `.onChange` (temp, rain, formality, garments, locked, etc.) call `refreshSuggestion()`. Guards reduce redundant calls but multiple dependencies can still cause repeated work. |
| **Planner: `updateAvailableGarments()`** | Builds a long signature string from all garments on main thread. Called from handleAppear, handleGarmentChange, markUnavailable. |

### Lower impact (already mitigated or one-off)

| Item | Note |
|------|------|
| **WeatherCenter** | Already throttled (1h min refresh, in-flight guard). |
| **CloudKit image uploads** | `CloudKitImageSyncService.enqueueUpload` fires one upload per garment (no batching), but uploads are off main thread and in-flight set prevents duplicates. |
| **EditGarmentView** | brandText `.onChange` only sets `hasUnsavedChanges`; save is on explicit Save tap. No per-keystroke persist. |

### CloudKit / persistence

- **No custom “deferred sync” layer**: SwiftData uses `NSPersistentCloudKitContainer`; every `context.save()` writes locally and pushes to CloudKit. To reduce sync frequency we must **debounce/batch the calls to `context.save()`** at call sites (planner, profile), not a separate CloudKit queue.
- **Recommendation**: Debounce planner persists (e.g. 10–15 s after last change), flush on scene phase `.background` and on critical actions (confirm worn/plan). Debounce profile pref saves and notification scheduling.

---

## 2. Implemented mitigations

1. **Planner persistence debounce**  
   - `persistDayPlan(dayIndex)` is debounced (e.g. 15 s) unless `immediate: true`.  
   - Dirty day indices are coalesced; one flush saves all dirty days.  
   - Flush on scene phase `.background` and for confirm worn/plan.

2. **ProfileView**  
   - Pref bindings no longer save on every toggle; a single debounced save (e.g. 3 s) after last change.  
   - `scheduleNotifications()` debounced (e.g. 5 s) so time picker / toggles don’t trigger many schedules.

3. **WardrobeView**  
   - `rebuildVisibleGarments()` debounced (e.g. 0.2 s) so rapid filter/sort changes trigger one rebuild.

4. **BootstrapView**  
   - Timer limited to a small number of icon cycles (e.g. 5) then invalidated to avoid indefinite repeats.

5. **Planner garment-change throttle (optional)**  
   - `handleGarmentChange` can be debounced (e.g. 1 s) so multiple quick `allGarments.count` changes (e.g. after a save) trigger one hydrate + generate.

---

## 3. Files changed (see implementation)

- `WearIt/Helpers/Debouncer.swift` (new)
- `WearIt/Views/OutfitPlannerView.swift`
- `WearIt/Views/ProfileView.swift`
- `WearIt/Views/WardrobeView.swift`
- `WearIt/BootstrapView.swift`
- `WearIt/Docs/BatteryCloudKitAuditReport.md` (this file)

---

## 4. Constraints respected

- No data loss: flush on background and on critical actions; debounce only coalesces rapid repeats.  
- Planner behavior unchanged: availability and generation logic untouched; only when we call `context.save()` is deferred.  
- Minimal changes: reused a single `Debouncer`; no new CloudKit layer.
