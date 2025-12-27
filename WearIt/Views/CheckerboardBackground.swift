import SwiftUI

struct CheckerboardBackground: View {
    var squareSize: CGFloat = 16
    var cornerRadius: CGFloat = 12

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let cols = Int(ceil(geo.size.width / squareSize))
            let rows = Int(ceil(geo.size.height / squareSize))

            let light = colorScheme == .dark
                ? Color.white.opacity(0.10)
                : Color.black.opacity(0.04)
            let dark = colorScheme == .dark
                ? Color.white.opacity(0.18)
                : Color.black.opacity(0.08)

            Canvas { context, size in
                for y in 0..<rows {
                    for x in 0..<cols {
                        let isDark = (x + y) % 2 == 0
                        let rect = CGRect(
                            x: CGFloat(x) * squareSize,
                            y: CGFloat(y) * squareSize,
                            width: squareSize,
                            height: squareSize
                        )
                        context.fill(
                            Path(rect),
                            with: .color(isDark ? dark : light)
                        )
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        CheckerboardBackground()
            .frame(width: 240, height: 140)

        CheckerboardBackground(squareSize: 10, cornerRadius: 20)
            .frame(width: 240, height: 140)
    }
    .padding()
    .background(.background)
}
