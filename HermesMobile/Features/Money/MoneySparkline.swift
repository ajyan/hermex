import SwiftUI

/// A 56 × 24 line of an account's recent daily balances.
struct MoneySparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard values.count > 1, let low = values.min(), let high = values.max() else { return }
            let span = high - low == 0 ? 1 : high - low
            var path = Path()
            for (i, value) in values.enumerated() {
                let point = CGPoint(
                    x: size.width * CGFloat(i) / CGFloat(values.count - 1),
                    y: size.height - 2 - (size.height - 4) * CGFloat((value - low) / span)
                )
                i == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 56, height: 24)
        .accessibilityHidden(true)
    }
}
