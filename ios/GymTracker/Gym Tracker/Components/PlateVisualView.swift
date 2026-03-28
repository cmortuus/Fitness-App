import SwiftUI

struct PlateVisualView: View {
    let totalWeight: Double
    let barWeight: Double
    let isLbs: Bool
    var oneSided: Bool = false

    private var plates: [PlateSlice] {
        calcPlates(totalWeight: totalWeight, barWeight: barWeight, isLbs: isLbs, oneSided: oneSided)
    }

    var body: some View {
        if plates.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 4) {
                // Visual bar + plates
                HStack(alignment: .center, spacing: 1) {
                    // Bar end cap
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.gray.opacity(0.6))
                        .frame(width: 8, height: 12)

                    // Bar
                    Rectangle()
                        .fill(.gray.opacity(0.4))
                        .frame(width: 30, height: 6)

                    // Plates (left side = both sides)
                    ForEach(Array(plates.enumerated()), id: \.offset) { _, plate in
                        ForEach(0..<plate.count, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(plate.color)
                                .frame(width: max(6, 4 + plate.heightFraction * 8),
                                       height: 20 + plate.heightFraction * 24)
                        }
                    }

                    // Collar
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.gray.opacity(0.5))
                        .frame(width: 4, height: 16)
                }
                .frame(height: 50)

                // Text breakdown
                let breakdown = plates.map { "\($0.count)×\(formatWeight($0.weight))" }.joined(separator: " + ") + (oneSided ? "" : " /side")
                Text(breakdown)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Plate layout: \(plates.map { "\($0.count) plates of \(formatWeight($0.weight))" }.joined(separator: ", "))\(oneSided ? "" : " per side")")
        }
    }

    private func formatWeight(_ w: Double) -> String {
        w == w.rounded() ? "\(Int(w))" : String(format: "%.1f", w)
    }
}
