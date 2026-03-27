import SwiftUI

struct ConfettiView: View {
    @State private var particles: [ConfettiParticle] = []
    @State private var animate = false

    let colors: [Color] = [.yellow, .red, .green, .blue, .purple, .orange, .pink, .teal]

    var body: some View {
        ZStack {
            ForEach(particles) { p in
                Circle()
                    .fill(p.color)
                    .frame(width: p.size, height: p.size)
                    .offset(x: animate ? p.endX : p.startX,
                            y: animate ? p.endY : -20)
                    .opacity(animate ? 0 : 1)
                    .rotationEffect(.degrees(animate ? p.rotation : 0))
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            particles = (0..<50).map { _ in
                ConfettiParticle(
                    color: colors.randomElement()!,
                    size: CGFloat.random(in: 4...10),
                    startX: CGFloat.random(in: -150...150),
                    endX: CGFloat.random(in: -200...200),
                    endY: CGFloat.random(in: 300...700),
                    rotation: Double.random(in: 180...720)
                )
            }
            withAnimation(.easeIn(duration: 2.0)) {
                animate = true
            }
        }
    }
}

struct ConfettiParticle: Identifiable {
    let id = UUID()
    let color: Color
    let size: CGFloat
    let startX: CGFloat
    let endX: CGFloat
    let endY: CGFloat
    let rotation: Double
}
