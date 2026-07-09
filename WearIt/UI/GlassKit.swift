//
//  GlassKit.swift
//  WearIt
//
//  Created by Dor David on 21/10/2025.
//  Updated for native iOS 26+ Liquid Glass with iOS 18+ fallbacks
//

import SwiftUI
import UIKit

// MARK: - Global ambient backdrop
public struct LiquidGlassBackdrop: View {
    public init() {}

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                // Keep one ambient layer behind the entire app. Glass surfaces need
                // real color and contrast behind them in order to feel transparent.
                if let wallpaper = UIImage(named: "WallpaperMock") {
                    Image(uiImage: wallpaper)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .blur(radius: 10)
                        .opacity(0.34)
                        .overlay(Color(.systemBackground).opacity(0.16))
                        .ignoresSafeArea()
                } else {
                    Color(.systemBackground)
                        .ignoresSafeArea()
                }

                // Static ambient color: no continuous animation or redraw cost.
                Canvas { ctx, size in
                    let phase = 0.0
                    let c1 = gradientBlob(center: movingPoint(size, phase: phase * 0.05, amp: 0.28),
                                          baseHue: 208/360, sat: 0.70, bri: 0.96)
                    let c2 = gradientBlob(center: movingPoint(size, phase: phase * 0.035 + 2.1, amp: 0.25),
                                          baseHue: 315/360, sat: 0.55, bri: 0.95)
                    let c3 = gradientBlob(center: movingPoint(size, phase: phase * 0.045 + 4.2, amp: 0.22),
                                          baseHue: 45/360, sat: 0.60, bri: 0.95)
                    let c4 = gradientBlob(center: movingPoint(size, phase: phase * 0.04 + 1.5, amp: 0.20),
                                          baseHue: 280/360, sat: 0.55, bri: 0.93)

                    ctx.addFilter(.blur(radius: 58))
                    ctx.addFilter(.saturation(0.92))

                    func drawBlob(_ blob: (gradient: Gradient, center: CGPoint)) {
                        let radius: CGFloat = 420
                        let rect = CGRect(x: blob.center.x - radius,
                                          y: blob.center.y - radius,
                                          width: radius * 2,
                                          height: radius * 2)
                        let path = Path(ellipseIn: rect)
                        ctx.fill(path, with: .radialGradient(
                            blob.gradient,
                            center: blob.center,
                            startRadius: 0,
                            endRadius: radius
                        ))
                    }

                    drawBlob(c1); drawBlob(c2); drawBlob(c3); drawBlob(c4)

                    let noiseOpacity: CGFloat = 0.014
                    ctx.blendMode = .overlay
                    if let noise = Self.cachedNoise(for: size) {
                        ctx.opacity = noiseOpacity
                        ctx.draw(noise, in: CGRect(origin: .zero, size: size))
                    }
                }
                .ignoresSafeArea()

                LinearGradient(
                    colors: [
                        Color.white.opacity(0.035),
                        Color(.systemBackground).opacity(0.10),
                        Color.black.opacity(0.025)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            }
        }
    }

    private func movingPoint(_ size: CGSize, phase: Double, amp: CGFloat) -> CGPoint {
        let w = size.width, h = size.height
        // תנועה חלקה יותר עם easing
        let x = w*0.5 + cos(phase) * w*amp
        let y = h*0.5 + sin(phase*0.87) * h*amp
        return CGPoint(x: x, y: y)
    }

    private func gradientBlob(center: CGPoint, baseHue: CGFloat, sat: CGFloat, bri: CGFloat)
    -> (gradient: Gradient, center: CGPoint) {
        // גרדיאנטים חלקים יותר עם יותר שלבים
        let colors = [
            Color(hue: baseHue, saturation: sat, brightness: bri, opacity: 0.32),
            Color(hue: baseHue, saturation: max(0, sat - 0.20), brightness: min(1, bri + 0.03), opacity: 0.17),
            Color(hue: baseHue, saturation: max(0, sat - 0.35), brightness: min(1, bri + 0.05), opacity: 0.06),
            .clear
        ]
        let gradient = Gradient(colors: colors)
        return (gradient, center)
    }

    // Cache רעש סטטי כדי להימנע מכתיבת state בזמן ציור
    private static var noiseCache: [String: Image] = [:]
    private static func cachedNoise(for size: CGSize) -> Image? {
        let key = "\(Int(size.width))x\(Int(size.height))"
        if let cached = noiseCache[key] { return cached }
        guard let generated = generateNoise(size: size) else { return nil }
        noiseCache[key] = generated
        return generated
    }

    private static func generateNoise(size: CGSize) -> Image? {
        let renderer = UIGraphicsImageRenderer(size: size)
        let ui = renderer.image { ctx in
            let cg = ctx.cgContext
            // רעש עדין יותר עם צפיפות דינמית
            let density = Int(size.width * size.height / 1800)
            for _ in 0..<max(1000, density) {
                let x = CGFloat.random(in: 0..<size.width)
                let y = CGFloat.random(in: 0..<size.height)
                let a = CGFloat.random(in: 0.015...0.06)
                cg.setFillColor(UIColor.white.withAlphaComponent(a).cgColor)
                cg.fill(CGRect(x: x, y: y, width: 1.5, height: 1.5))
            }
        }
        return Image(uiImage: ui)
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
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
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
