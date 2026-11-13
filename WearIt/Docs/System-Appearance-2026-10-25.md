# System appearance and shared surfaces — 2026-10-25

Dor requested automatic light/dark appearance from device settings and a polished, consistent app presentation. Implemented locally and reviewed in source only. No build, tests, simulator, app launch, rendered preview, commit or publication was performed; visual acceptance remains an owner device check.

## Result

- Removed the root and sign-in `preferredColorScheme` overrides. Background choice and photo luminance no longer determine app appearance. SwiftUI inherits system changes, including while the app is open.
- Added the `system` backdrop as the default when no preset is stored, with a native grouped background and a separate adaptive card surface. Existing explicit preset/photo choices are retained; no stored settings are reset.
- Built-in colored backgrounds now use restrained light palettes and distinct dark palettes. Settings previews read the same environment scheme and palette as the actual backdrop.
- Shared content cards use opaque `secondarySystemGroupedBackground` over the grouped canvas, with restrained borders and a stronger Today outline. Dark cards remain visually separated from the canvas. Glass stays on existing controls/chrome; there is no new live wallpaper blur or extra content shadow stack.
- Photo backgrounds use a light/dark semantic veil so wallpaper brightness cannot choose the text color or overwhelm labels. Reduce Transparency/Increase Contrast simplify the background to the system canvas and strengthen card outlines. Wallpaper files are retained.
- System appearance changes only recolor/composite the backdrop. They do not change the photo preparation task identity or trigger a new photo decode. Photo loading remains downsampled/off-main and now discards cancelled results.
- Sign-in typography, account cards, secondary actions and Apple buttons adapt to the system appearance. Onboarding's Apple button adapts too. The shop photo gallery no longer forces a dark presentation. Existing image-cropping/media-overlay canvases retain their purpose-specific black/white treatment.
- Selected occasion chips in Edit use `DS.Accent.onFill`, matching the existing dark/light accent asset, instead of white on the light accent used in dark appearance.
- EN/HE Settings copy now explains automatic system appearance and includes the new System background chip. No new appearance-mode switch, profile model or migration was added.

The startup photo-luminance backfill was removed along with its root-only purpose, eliminating that synchronous full-image read. Legacy `customImageIsDark` metadata and image store compatibility remain, but that key does not select appearance. The earlier backdrop-driven appearance notes are superseded by this change.

## Source scope

| File | Change |
| --- | --- |
| `RootView.swift` | Inherit system appearance; remove wallpaper-based mode selection/backfill |
| `UI/AppBackdropPreference.swift` | System preset, paired palettes and legacy metadata note |
| `UI/GlassKit.swift` | Environment-based palettes/photo veil/accessibility/cancelled result guard |
| `UI/DesignSystem.swift` | Grouped canvas, adaptive content surface and clear card hierarchy |
| `Views/SettingsView.swift` | Adaptive palette previews and default/removed-photo fallback |
| `Views/SignInView.swift`, `Views/OnboardingView.swift` | Adaptive account controls/Apple buttons |
| `Views/ShopProductDetailsView.swift` | Gallery inherits system appearance |
| `Views/EditGarmentView.swift` | Selected accent-fill label contrast |
| `en.lproj/Localizable.strings`, `he.lproj/Localizable.strings` | Appearance copy and System preset |

## Owner device review

1. Build in Xcode. Switch the device between light/dark while viewing Outfits, Calendar, Wardrobe, Shopping and Add. Verify titles, bars, cards, dates and action buttons update immediately without restarting.
2. Open Profile → Settings → Appearance. Choose System for the neutral canvas, then check each colored preset in both modes. Existing saved choices should remain selected across relaunch.
3. Try both a very light and a very dark custom photo. Check toolbar text, captions and glass controls, then change appearance with the photo selected. Photo brightness should not force the app into another mode.
4. Check sign-in, replayed onboarding, item-edit selected occasion chips and the shop photo gallery in both modes. No white-on-white sign-in labels or white labels on a pale accent fill.
5. Check Increase Contrast and Reduce Transparency separately and together. Verify background simplification without loss of saved photo/preferences. Review Hebrew RTL, narrow layouts and large text.
6. Review actual dark card elevation, light card separation, colored preset saturation and photo visibility on device. No measured contrast ratio, rendered-design acceptance or performance improvement is claimed from source inspection.

## References checked

- [Apple: Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode) — honor device appearance, semantic colors and elevated surfaces.
- [Apple: colorScheme](https://developer.apple.com/documentation/swiftui/environmentvalues/colorscheme) — environment changes update dependent views.
- [Apple: preferredColorScheme](https://developer.apple.com/documentation/swiftui/view/preferredcolorscheme(_:)) — an explicit preference overrides the system for its presentation.

All unrelated wardrobe/planner/shopping/crawler edits remain in place. The shopping compiler follow-up and owner runtime review from earlier work are still pending independently.
