import SwiftUI

struct StatusIcon: View {
    // MARK: Internal

    let phase: Double

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let centerY = height / 2

            ZStack {
                // Grid lines
                Path { path in
                    // Horizontal lines
                    for y in stride(from: 0, through: height, by: height / 4) {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: width, y: y))
                    }
                    // Vertical lines
                    for x in stride(from: 0, through: width, by: width / 4) {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: height))
                    }
                }
                .stroke(Color.white.opacity(0.2), lineWidth: 0.3)

                // ECG Waveform
                Path { path in
                    path.move(to: CGPoint(x: 0, y: centerY))

                    for x in stride(from: 0, through: width, by: 0.5) {
                        let y = centerY - self.ecgWaveform(x: x, width: width)
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                .stroke(
                    Color.white,
                    style: StrokeStyle(
                        lineWidth: 1.2,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
        }
    }

    // MARK: Private

    private func ecgWaveform(x: Double, width: Double) -> Double {
        let normalizedX = x / width
        let cycle = (normalizedX + self.phase).truncatingRemainder(dividingBy: 1.0)

        // One complete heartbeat takes up 40% of the cycle, leaving 60% for the flat line
        let heartbeatCycle = cycle / 0.4

        // P wave (small bump)
        if heartbeatCycle >= 0.0, heartbeatCycle < 0.15 {
            return sin((heartbeatCycle / 0.15) * .pi) * 2
        }
        // PR segment (flat line)
        else if heartbeatCycle >= 0.15, heartbeatCycle < 0.25 {
            return 0
        }
        // QRS complex (sharp spike)
        else if heartbeatCycle >= 0.25, heartbeatCycle < 0.35 {
            if heartbeatCycle < 0.27 {
                return -2 // Q wave
            } else if heartbeatCycle < 0.30 {
                return 8 // R wave
            } else {
                return -4 // S wave
            }
        }
        // ST segment (flat line)
        else if heartbeatCycle >= 0.35, heartbeatCycle < 0.45 {
            return 0
        }
        // T wave (rounded bump)
        else if heartbeatCycle >= 0.45, heartbeatCycle < 0.55 {
            return sin((heartbeatCycle - 0.45) / 0.1 * .pi) * 3
        }
        // Rest of the cycle (flat line)
        else {
            return 0
        }
    }
}
