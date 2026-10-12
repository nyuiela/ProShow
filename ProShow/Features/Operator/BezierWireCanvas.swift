import SwiftUI

public struct BezierWireCanvas: View {
    public let connections: [CableConnection]
    public let portPositions: [UUID: CGPoint]
    public let activeDragWire: (start: CGPoint, end: CGPoint)?
    public var laser: (start: CGPoint, end: CGPoint)?
    public var disabledIDs: Set<UUID>
    public var reduceMotion: Bool

    public init(
        connections: [CableConnection],
        portPositions: [UUID: CGPoint],
        activeDragWire: (start: CGPoint, end: CGPoint)? = nil,
        laser: (start: CGPoint, end: CGPoint)? = nil,
        disabledIDs: Set<UUID> = [],
        reduceMotion: Bool = false
    ) {
        self.connections = connections
        self.portPositions = portPositions
        self.activeDragWire = activeDragWire
        self.laser = laser
        self.disabledIDs = disabledIDs
        self.reduceMotion = reduceMotion
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 10 : 1.0 / 24.0, paused: reduceMotion)) { timeline in
            let pulse = reduceMotion
                ? 0
                : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.25) / 1.25
            wires(pulse: pulse)
        }
    }

    private func wires(pulse: Double) -> some View {
        Canvas { context, _ in
            for connection in connections {
                guard let start = portPositions[connection.startPortId],
                      let end = portPositions[connection.endPortId] else { continue }

                let path = Self.calculateBezierPath(from: start, to: end)
                let style = Self.cableStyle(for: connection, disabled: disabledIDs.contains(connection.id))
                context.stroke(
                    path,
                    with: .color(style.color),
                    style: SwiftUI.StrokeStyle(lineWidth: style.lineWidth, lineCap: .round, dash: style.dashPattern)
                )
                if connection.isLive, !reduceMotion, !disabledIDs.contains(connection.id) {
                    let samples = NodeGraphGeometry.sampleBezier(from: start, to: end, steps: 18)
                    let offset = Int((pulse * Double(samples.count - 1)).rounded()) % max(samples.count, 1)
                    if samples.indices.contains(offset) {
                        let dot = samples[offset]
                        context.fill(Path(ellipseIn: CGRect(x: dot.x - 2.5, y: dot.y - 2.5, width: 5, height: 5)), with: .color(.white.opacity(0.85)))
                    }
                }
            }

            if let drag = activeDragWire {
                let dragPath = Self.calculateBezierPath(from: drag.start, to: drag.end)
                context.stroke(
                    dragPath,
                    with: .color(.accentColor.opacity(0.85)),
                    style: SwiftUI.StrokeStyle(lineWidth: 2, lineCap: .round, dash: [8, 4])
                )
            }

            if let laser {
                var cut = Path()
                cut.move(to: laser.start)
                cut.addLine(to: laser.end)
                context.stroke(cut, with: .color(.red.opacity(0.92)), style: SwiftUI.StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
            }
        }
        .allowsHitTesting(false)
    }

    public static func calculateBezierPath(from start: CGPoint, to end: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        let deltaX = abs(end.x - start.x) * 0.5
        let control1 = CGPoint(x: start.x + max(deltaX, 40), y: start.y)
        let control2 = CGPoint(x: end.x - max(deltaX, 40), y: end.y)
        path.addCurve(to: end, control1: control1, control2: control2)
        return path
    }

    public static func cableStyle(
        for connection: CableConnection,
        disabled: Bool = false
    ) -> (color: Color, lineWidth: CGFloat, dashPattern: [CGFloat]) {
        if disabled {
            return (.gray.opacity(0.45), 1.5, [5, 5])
        }
        if connection.isFailoverActive {
            return (.orange.opacity(0.9), 2.4, [6, 4])
        }
        if connection.isLive {
            return (.red.opacity(0.9), 2.5, [])
        }
        if connection.isPreview {
            return (.green.opacity(0.85), 2, [])
        }
        return (.cyan.opacity(0.62), 2, [])
    }
}

struct GridPatternBackground: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 24
            var grid = Path()
            var x: CGFloat = 0
            while x <= size.width {
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            context.stroke(grid, with: .color(Color.white.opacity(0.045)), lineWidth: 1)
        }
        .background(Color.black.opacity(0.35))
        .allowsHitTesting(false)
    }
}
