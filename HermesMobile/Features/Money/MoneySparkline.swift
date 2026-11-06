import SwiftUI

/// A 56 × 24 line of an account's recent daily balances, or a spending category's months.
struct MoneySparkline: View {
    let values: [Double]
    let color: Color
    /// Scale from zero rather than the lowest value, so a small dip looks small.
    var fromZero = false
    /// Dash the last step: a month still going.
    var dashesLast = false

    var body: some View {
        Canvas { context, size in
            guard values.count > 1, let low = fromZero ? 0 : values.min(), let high = values.max() else { return }
            let span = high - low == 0 ? 1 : high - low
            let points = values.enumerated().map { i, value in
                CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1),
                        y: size.height - 2 - (size.height - 4) * CGFloat((value - low) / span))
            }
            let solid = dashesLast ? Array(points.dropLast()) : points
            var path = Path()
            path.addLines(solid)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            if dashesLast, let from = solid.last, let to = points.last {
                var tail = Path()
                tail.addLines([from, to])
                context.stroke(tail, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 3]))
            }
        }
        .frame(width: 56, height: 24)
        .accessibilityHidden(true)
    }
}
