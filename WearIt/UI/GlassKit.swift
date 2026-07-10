//
//  GlassKit.swift
//  WearIt
//
//  Created by Dor David on 21/10/2025.
//  Updated for native iOS 26+ Liquid Glass with iOS 18+ fallbacks
//

import SwiftUI
import UIKit
import CoreImage

// MARK: - Global ambient backdrop (simple + reliable)

public struct LiquidGlassBackdrop: View {
    @AppStorage(AppBackdropKeys.preset) private var presetRaw: String = AppBackdropPreset.softSky.rawValue
    @AppStorage(AppBackdropKeys.customImagePath) private var customImagePath: String = ""
    @AppStorage(AppBackdropKeys.blurAmount) private var blurAmount: Double = AppBackdropBlur.defaultAmount

    @State private var photo: UIImage?

    public init() {}

    private var preset: AppBackdropPreset {
        AppBackdropPreset(rawValue: presetRaw) ?? .softSky
    }

    private var blurRadius: CGFloat {
        // Cap for scroll performance — still readable under glass.
        min(AppBackdropBlur.radius(for: blurAmount), 18)
    }

    private var fillColors: [Color] {
        if preset == .photo {
            return AppBackdropPreset.softSky.previewColors
        }
        return preset.previewColors
    }

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: fillColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // `photo` is already downsampled (and softly blurred offline) —
            // never apply live SwiftUI `.blur` here; that tanks scroll FPS.
            // Constrain fill so scaledToFill cannot expand parent layout.
            if preset == .photo, let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
            }

            Color(.systemBackground)
                .opacity(AppBackdropBlur.veilOpacity(for: blurAmount))
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(false)
        .task(id: "\(presetRaw)|\(customImagePath)|\(Int((blurAmount * 100).rounded()))") {
            guard preset == .photo, !customImagePath.isEmpty else {
                photo = nil
                return
            }
            let path = customImagePath
            let radius = blurRadius
            photo = await Task.detached(priority: .utility) {
                Self.prepareWallpaper(path: path, blurRadius: radius)
            }.value
        }
    }

    /// Downsample + optional one-shot blur off the main thread.
    nonisolated private static func prepareWallpaper(path: String, blurRadius: CGFloat) -> UIImage? {
        // Prefer a modest decode size — full-screen wallpaper doesn't need 4K.
        let maxPixel = min(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * UIScreen.main.scale
        guard let base = ImageStore.loadThumbnail(path: path, maxPixelSize: maxPixel)
                ?? ImageStore.loadImage(path: path) else { return nil }
        guard blurRadius > 0.5, let cg = base.cgImage else { return base }

        let ciImage = CIImage(cgImage: cg)
        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(blurRadius, forKey: kCIInputRadiusKey)
        guard let output = filter?.outputImage?.cropped(to: ciImage.extent) else { return base }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let result = context.createCGImage(output, from: ciImage.extent) else { return base }
        return UIImage(cgImage: result, scale: base.scale, orientation: base.imageOrientation)
    }
}

// MARK: - Native glass primitives

public struct LiquidGlassGroup<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    public init(spacing: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    public var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

private struct AdaptiveGlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    let padding: CGFloat
    let interactive: Bool
    let tint: Color?
    let fallbackMaterial: Material
    let castsShadow: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if interactive {
                content
                    .padding(padding)
                    .glassEffect(
                        .regular.tint(tint).interactive(),
                        in: .rect(cornerRadius: cornerRadius)
                    )
                    .shadow(
                        color: castsShadow ? Color.black.opacity(0.07) : .clear,
                        radius: castsShadow ? 16 : 0,
                        y: castsShadow ? 8 : 0
                    )
            } else {
                content
                    .padding(padding)
                    .glassEffect(
                        .regular.tint(tint),
                        in: .rect(cornerRadius: cornerRadius)
                    )
                    .shadow(
                        color: castsShadow ? Color.black.opacity(0.07) : .clear,
                        radius: castsShadow ? 16 : 0,
                        y: castsShadow ? 8 : 0
                    )
            }
        } else {
            content
                .padding(padding)
                .background(
                    fallbackMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.24), .white.opacity(0.06)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.6
                        )
                        .blendMode(.plusLighter)
                )
                .shadow(
                    color: castsShadow ? Color.black.opacity(0.07) : .clear,
                    radius: castsShadow ? 16 : 0,
                    y: castsShadow ? 8 : 0
                )
        }
    }
}

private struct AdaptiveGlassPill: ViewModifier {
    let interactive: Bool
    let tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if interactive {
                content.glassEffect(.regular.tint(tint).interactive(), in: .capsule)
            } else {
                content.glassEffect(.regular.tint(tint), in: .capsule)
            }
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.6))
        }
    }
}

private struct AdaptiveGlassCircle: ViewModifier {
    let interactive: Bool
    let tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if interactive {
                content.glassEffect(.regular.tint(tint).interactive(), in: .circle)
            } else {
                content.glassEffect(.regular.tint(tint), in: .circle)
            }
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.6))
        }
    }
}

// MARK: - Glass Card Modifier
public struct GlassCard: ViewModifier {
    public init(corner: CGFloat = 24, strokeOpacity: CGFloat = 0.30, intensity: MaterialIntensity = .ultraThin) {
        self.corner = corner
        self.strokeOpacity = strokeOpacity
        self.intensity = intensity
    }
    let corner: CGFloat
    let strokeOpacity: CGFloat
    let intensity: MaterialIntensity
    
    public enum MaterialIntensity {
        case thin
        case regular
        case thick
        case ultraThin
        
        var material: Material {
            switch self {
            case .thin: return .thinMaterial
            case .regular: return .regularMaterial
            case .thick: return .thickMaterial
            case .ultraThin: return .ultraThinMaterial
            }
        }
    }

    public func body(content: Content) -> some View {
        content
            .modifier(
                AdaptiveGlassSurface(
                    cornerRadius: corner,
                    padding: 16,
                    interactive: false,
                    tint: nil,
                    fallbackMaterial: intensity.material,
                    castsShadow: true
                )
            )
    }
}

// MARK: - Glass Button Style (iOS 18+)
public struct GlassButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat
    let material: Material
    
    public init(cornerRadius: CGFloat = 16, material: Material = .ultraThinMaterial) {
        self.cornerRadius = cornerRadius
        self.material = material
    }
    
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                material,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(0.25),
                        lineWidth: 0.8
                    )
                    .blendMode(.plusLighter)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(DS.Animation.interactive, value: configuration.isPressed)
    }
}

// MARK: - Glass List Row Modifier
public struct GlassListRow: ViewModifier {
    let cornerRadius: CGFloat
    
    public init(cornerRadius: CGFloat = 12) {
        self.cornerRadius = cornerRadius
    }
    
    public func body(content: Content) -> some View {
        content
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .modifier(
                AdaptiveGlassSurface(
                    cornerRadius: cornerRadius,
                    padding: 0,
                    interactive: false,
                    tint: nil,
                    fallbackMaterial: .ultraThinMaterial,
                    castsShadow: false
                )
            )
    }
}

public extension View {
    func liquidGlassSurface(
        cornerRadius: CGFloat = 18,
        padding: CGFloat = 0,
        interactive: Bool = false,
        tint: Color? = nil,
        fallbackMaterial: Material = .ultraThinMaterial,
        castsShadow: Bool = false
    ) -> some View {
        modifier(
            AdaptiveGlassSurface(
                cornerRadius: cornerRadius,
                padding: padding,
                interactive: interactive,
                tint: tint,
                fallbackMaterial: fallbackMaterial,
                castsShadow: castsShadow
            )
        )
    }

    func liquidGlassPill(interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(AdaptiveGlassPill(interactive: interactive, tint: tint))
    }

    func liquidGlassCircle(interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(AdaptiveGlassCircle(interactive: interactive, tint: tint))
    }

    /// הופך כל View לכרטיס זכוכית מוכן (iOS 18+)
    func glassCard(corner: CGFloat = 24, intensity: GlassCard.MaterialIntensity = .ultraThin) -> some View {
        modifier(GlassCard(corner: corner, intensity: intensity))
    }
    
    /// הופך View לכפתור זכוכית
    @ViewBuilder
    func glassButton(cornerRadius: CGFloat = 16, material: Material = .ultraThinMaterial) -> some View {
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glass)
                .buttonBorderShape(.roundedRectangle(radius: cornerRadius))
        } else {
            self.buttonStyle(GlassButtonStyle(cornerRadius: cornerRadius, material: material))
        }
    }
    
    /// הופך View לשורת רשימה זכוכית
    func glassListRow(cornerRadius: CGFloat = 12) -> some View {
        modifier(GlassListRow(cornerRadius: cornerRadius))
    }
}
// MARK: - Debug Username Login (Temporary, no auth)
public extension View {
    /// מציג sheet זמני להתחברות עם שם משתמש בלבד (ללא אימות) לצורכי בדיקה.
    /// Usage:
    /// .debugUsernameLoginSheet(isPresented: $showLogin) { username in
    ///     // עדכון AuthManager למשל: auth.userIdentifier = username
    /// }
    func debugUsernameLoginSheet(isPresented: Binding<Bool>, onLogin: @escaping (String) -> Void) -> some View {
        self.sheet(isPresented: isPresented) {
            UsernameLoginSheet(isPresented: isPresented, onLogin: onLogin)
                .presentationDetents([.fraction(0.35), .medium])
                .presentationDragIndicator(.visible)
        }
    }
}

private struct UsernameLoginSheet: View {
    @Binding var isPresented: Bool
    let onLogin: (String) -> Void
    @State private var username: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Debug Login")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
            }

            Text("Enter any username to simulate a logged-in user. No authentication is performed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("Username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .submitLabel(.done)
                .focused($focused)
                .padding(12)
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
                        .blendMode(.plusLighter)
                )

            Button {
                let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                onLogin(trimmed)
                isPresented = false
            } label: {
                Label("Login as Username", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .glassButton(cornerRadius: 14, material: .thinMaterial)
            .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button(role: .cancel) {
                isPresented = false
            } label: {
                Text("Cancel")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
        .glassCard(corner: 20, intensity: .ultraThin)
        .padding()
        .onAppear { focused = true }
    }
}
