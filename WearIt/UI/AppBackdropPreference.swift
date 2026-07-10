//
//  AppBackdropPreference.swift
//  WearIt
//
//  User-selectable app backdrop + blur amount so liquid glass can float over it.
//

import SwiftUI
import UIKit

enum AppBackdropPreset: String, CaseIterable, Identifiable {
    case softSky
    case warmSand
    case mistForest
    case duskRose
    case slate
    case photo

    var id: String { rawValue }

    var titleKey: LocalizedStringResource {
        switch self {
        case .softSky: return "backdrop_soft_sky"
        case .warmSand: return "backdrop_warm_sand"
        case .mistForest: return "backdrop_mist_forest"
        case .duskRose: return "backdrop_dusk_rose"
        case .slate: return "backdrop_slate"
        case .photo: return "backdrop_photo"
        }
    }

    /// Preview / fill colors for built-in presets (top → bottom).
    var previewColors: [Color] {
        switch self {
        case .softSky:
            return [
                Color(red: 0.72, green: 0.84, blue: 0.95),
                Color(red: 0.88, green: 0.92, blue: 0.97),
                Color(red: 0.96, green: 0.94, blue: 0.90)
            ]
        case .warmSand:
            return [
                Color(red: 0.93, green: 0.86, blue: 0.76),
                Color(red: 0.96, green: 0.91, blue: 0.84),
                Color(red: 0.90, green: 0.82, blue: 0.72)
            ]
        case .mistForest:
            return [
                Color(red: 0.55, green: 0.68, blue: 0.58),
                Color(red: 0.72, green: 0.80, blue: 0.72),
                Color(red: 0.86, green: 0.88, blue: 0.82)
            ]
        case .duskRose:
            return [
                Color(red: 0.78, green: 0.62, blue: 0.68),
                Color(red: 0.90, green: 0.78, blue: 0.76),
                Color(red: 0.94, green: 0.88, blue: 0.84)
            ]
        case .slate:
            return [
                Color(red: 0.42, green: 0.48, blue: 0.56),
                Color(red: 0.58, green: 0.62, blue: 0.68),
                Color(red: 0.78, green: 0.80, blue: 0.84)
            ]
        case .photo:
            return [
                Color(.systemGray3),
                Color(.systemGray5)
            ]
        }
    }

    var ambientHues: [CGFloat] {
        switch self {
        case .softSky: return [208 / 360, 200 / 360, 45 / 360, 220 / 360]
        case .warmSand: return [35 / 360, 28 / 360, 18 / 360, 42 / 360]
        case .mistForest: return [130 / 360, 145 / 360, 95 / 360, 160 / 360]
        case .duskRose: return [340 / 360, 15 / 360, 300 / 360, 20 / 360]
        case .slate: return [210 / 360, 220 / 360, 200 / 360, 230 / 360]
        case .photo: return [208 / 360, 315 / 360, 45 / 360, 280 / 360]
        }
    }
}

enum AppBackdropKeys {
    static let preset = "appBackdropPreset"
    static let customImagePath = "appBackdropCustomImagePath"
    /// 0...1 — mapped to blur radius in `LiquidGlassBackdrop`.
    static let blurAmount = "appBackdropBlurAmount"
}

enum AppBackdropBlur {
    /// Default: light blur so the image stays readable under glass.
    static let defaultAmount: Double = 0.35
    static let minRadius: CGFloat = 0
    static let maxRadius: CGFloat = 24

    static func radius(for amount: Double) -> CGFloat {
        let t = min(max(amount, 0), 1)
        return minRadius + CGFloat(t) * (maxRadius - minRadius)
    }

    static func scale(for amount: Double) -> CGFloat {
        let t = min(max(amount, 0), 1)
        return 1.0 + CGFloat(t) * 0.10
    }

    static func veilOpacity(for amount: Double) -> Double {
        0.03 + min(max(amount, 0), 1) * 0.08
    }

    static func ambientOpacity(for amount: Double) -> Double {
        0.18 + min(max(amount, 0), 1) * 0.40
    }
}

enum AppBackdropStore {
    static func saveCustomImage(_ image: UIImage) -> String? {
        let prepared = image.resized(toMaxDimension: 1600)
        guard let data = prepared.jpegData(compressionQuality: 0.82) else { return nil }
        do {
            if let old = UserDefaults.standard.string(forKey: AppBackdropKeys.customImagePath) {
                ImageStore.delete(path: old)
            }
            let path = try ImageStore.save(data: data, preferredExt: "jpg")
            UserDefaults.standard.set(path, forKey: AppBackdropKeys.customImagePath)
            UserDefaults.standard.set(AppBackdropPreset.photo.rawValue, forKey: AppBackdropKeys.preset)
            return path
        } catch {
            return nil
        }
    }

    static func clearCustomImage() {
        if let old = UserDefaults.standard.string(forKey: AppBackdropKeys.customImagePath) {
            ImageStore.delete(path: old)
        }
        UserDefaults.standard.removeObject(forKey: AppBackdropKeys.customImagePath)
    }

    static func loadCustomImage() -> UIImage? {
        guard let path = UserDefaults.standard.string(forKey: AppBackdropKeys.customImagePath) else {
            return nil
        }
        return ImageStore.loadImage(path: path)
    }
}

// MARK: - Transparent UIKit hosts

private struct ClearHostingBackground: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.isOpaque = false
        // Clear once on attach — do not re-walk the hierarchy every SwiftUI update.
        DispatchQueue.main.async { Self.clear(from: view) }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Intentionally empty: repeated clears during scroll cause main-thread jank.
    }

    private static func clear(from view: UIView) {
        var node: UIView? = view
        while let current = node {
            current.backgroundColor = .clear
            current.isOpaque = false
            node = current.superview
        }
        var responder: UIResponder? = view
        while let current = responder {
            if let vc = current as? UIViewController {
                vc.view.backgroundColor = .clear
                vc.view.isOpaque = false
                if let nav = vc.navigationController {
                    nav.view.backgroundColor = .clear
                    nav.view.isOpaque = false
                    nav.navigationBar.isTranslucent = true
                    nav.navigationBar.backgroundColor = .clear
                }
                if let tab = vc.tabBarController {
                    tab.view.backgroundColor = .clear
                    tab.view.isOpaque = false
                    tab.tabBar.isTranslucent = true
                    tab.tabBar.backgroundColor = .clear
                    tab.tabBar.barTintColor = .clear
                }
            }
            responder = current.next
        }
    }
}

extension View {
    /// Full-bleed backdrop chrome: no opaque nav/tab material bars.
    func withLocalAppBackdrop() -> some View {
        background { ClearHostingBackground() }
            .scrollContentBackground(.hidden)
            // Keep title/buttons; hide the bar fill so wallpaper continues edge-to-edge.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarBackground(.hidden, for: .tabBar)
    }

    /// Paints backdrop behind this screen without breaking safe-area layout.
    /// IMPORTANT: use `.background`, not a ZStack — a ZStack + ignoresSafeArea
    /// expands content under the status bar / home indicator.
    func withLocalAppBackdropPainted() -> some View {
        self
            .background {
                LiquidGlassBackdrop()
                    .clipped()
                    .ignoresSafeArea()
            }
            .withLocalAppBackdrop()
    }
}
