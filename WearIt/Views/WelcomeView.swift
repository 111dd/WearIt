import SwiftUI

struct WelcomeView: View {
    private let heroImages: [URL] = [
        URL(string: "https://storage.googleapis.com/uxpilot-auth.appspot.com/06e4c4ba06-8f666b7f8157453995c7.png")!,
        URL(string: "https://storage.googleapis.com/uxpilot-auth.appspot.com/c2cc640f5a-cacac3d0d80ec53e9437.png")!,
        URL(string: "https://storage.googleapis.com/uxpilot-auth.appspot.com/5db2113fa6-18187a1210589912831b.png")!
    ]

    var body: some View {
        ZStack {
            ambientOrbs

            GeometryReader { geo in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: DS.Spacing.xl) {
                        header

                        hero

                        valueProposition

                        capabilityRows

                        Spacer(minLength: DS.Spacing.lg)

                        primaryAction

                        secondaryAction

                        footer
                    }
                    .frame(minHeight: geo.size.height, alignment: .top)
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.top, 56)
                    .padding(.bottom, DS.Spacing.xxl)
                }
            }
        }
        .foregroundStyle(.white)
    }

    private var ambientOrbs: some View {
        ZStack {
            Circle()
                .fill(Color.blue.opacity(0.35))
                .frame(width: 280, height: 280)
                .blur(radius: 90)
                .offset(x: -140, y: -180)
                .opacity(0.7)

            Circle()
                .fill(Color.indigo.opacity(0.30))
                .frame(width: 240, height: 240)
                .blur(radius: 90)
                .offset(x: 140, y: 120)
                .opacity(0.6)

            Circle()
                .fill(Color.purple.opacity(0.25))
                .frame(width: 180, height: 180)
                .blur(radius: 90)
                .offset(x: -40, y: 140)
                .opacity(0.5)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(spacing: DS.Spacing.xs) {
            ZStack {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.blue.opacity(0.8))
            }
            .frame(width: 48, height: 48)
            .liquidGlassSurface(cornerRadius: DS.Radius.lg, tint: Color.blue.opacity(0.08), castsShadow: true)
            .padding(.bottom, DS.Spacing.xs)

            Text("WearIt")
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            Text("Wardrobe Intelligence")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.6))
                .textCase(.uppercase)
                .tracking(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DS.Spacing.sm)
    }

    private var hero: some View {
        ZStack {
            HeroTile(url: heroImages[0], size: CGSize(width: 96, height: 128), corner: 18)
                .rotationEffect(.degrees(-6))
                .offset(x: -80, y: -20)

            HeroTile(url: heroImages[1], size: CGSize(width: 112, height: 112), corner: 56)
                .rotationEffect(.degrees(6))
                .offset(x: 80, y: 30)

            HeroTile(url: heroImages[2], size: CGSize(width: 84, height: 84), corner: 18)
                .rotationEffect(.degrees(12))
                .offset(x: 60, y: -50)
        }
        .frame(height: 240)
    }

    private var valueProposition: some View {
        VStack(spacing: DS.Spacing.sm) {
            Text("Outfit confidence\nin seconds.")
                .font(.system(size: 24, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)

            Text("Plan today and the next two days with weather-aware recommendations from your real wardrobe.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
    }

    private var capabilityRows: some View {
        LiquidGlassGroup(spacing: DS.Spacing.sm) {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text("Seamless Experience")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .textCase(.uppercase)
                    .tracking(1.5)
                    .padding(.horizontal, 4)

                CapabilityRow(
                    icon: "cloud.sun.fill",
                    iconTint: .blue,
                    title: "Weather Sync",
                    subtitle: "Plans match temperature & rain"
                )

                CapabilityRow(
                    icon: "camera.fill",
                    iconTint: .purple,
                    title: "Photo Access",
                    subtitle: "Capture your real wardrobe"
                )

                CapabilityRow(
                    icon: "calendar.badge.checkmark",
                    iconTint: .orange,
                    title: "Smart Calendar",
                    subtitle: "Track looks & occasions"
                )
            }
        }
    }

    private var primaryAction: some View {
        Button(action: {}) {
            HStack(spacing: 8) {
                Text("Get Started")
                Image(systemName: "arrow.right")
                    .font(.footnote.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryGradientButtonStyle())
    }

    private var secondaryAction: some View {
        Button(action: {}) {
            Text("I already have an account")
                .frame(maxWidth: .infinity)
        }
        .glassButton(cornerRadius: 18, material: .ultraThinMaterial)
    }

    private var footer: some View {
        Text("By continuing, you agree to our\nTerms of Service and Privacy Policy")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.45))
            .multilineTextAlignment(.center)
            .padding(.top, DS.Spacing.sm)
            .padding(.horizontal, 20)
    }
}

private struct HeroTile: View {
    let url: URL
    let size: CGSize
    let corner: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            default:
                Color.white.opacity(0.12)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .liquidGlassSurface(cornerRadius: corner)
        .shadow(color: Color.black.opacity(0.25), radius: 16, x: 0, y: 10)
    }
}

private struct CapabilityRow: View {
    let icon: String
    let iconTint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(iconTint.opacity(0.18))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconTint.opacity(0.9))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer()

            Circle()
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                .frame(width: 18, height: 18)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .liquidGlassSurface(cornerRadius: 18)
        .shadow(color: Color.black.opacity(0.18), radius: 14, x: 0, y: 8)
    }
}

private struct PrimaryGradientButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.36, green: 0.55, blue: 1.0), Color(red: 0.49, green: 0.64, blue: 1.0)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .shadow(color: Color.blue.opacity(0.35), radius: 18, x: 0, y: 10)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(DS.Animation.fast, value: configuration.isPressed)
    }
}

#Preview {
    WelcomeView()
}
