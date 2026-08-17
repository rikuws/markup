import SwiftUI

/// A continuous rounded rect whose silhouette can travel as a damped
/// wave around the rim. Resting (amplitude ≈ 0) matches the live
/// Liquid Glass pane; while waving, each point is pushed along its
/// outward normal so the glass itself looks like it turned liquid.
struct LiquidWaveShape: InsettableShape {
    var cornerRadius: CGFloat
    /// Inset from the view bounds so outward crests stay inside the
    /// hosting view (and unclipped) while the rest pose still matches
    /// the selection rectangle.
    var pad: CGFloat
    var amplitude: CGFloat
    /// Travel along the perimeter, in revolutions.
    var phase: CGFloat
    /// Normalized perimeter position (0...1) where the release landed.
    var origin: CGFloat
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> LiquidWaveShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let work = restRect(in: rect)
        guard work.width > 1, work.height > 1 else { return Path() }

        let radius = min(cornerRadius, min(work.width, work.height) / 2)
        let base = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: work)
        guard amplitude >= 0.35 else { return base }

        let samples = Self.sample(base, spacing: 3.5)
        guard samples.count >= 8 else { return base }

        let center = CGPoint(x: work.midX, y: work.midY)
        let count = samples.count
        var path = Path()

        for index in 0..<count {
            let point = samples[index]
            let previous = samples[(index + count - 1) % count]
            let next = samples[(index + 1) % count]
            let normal = Self.outwardNormal(at: point, previous: previous, next: next, center: center)
            let t = CGFloat(index) / CGFloat(count)
            let offset = Self.displacement(t: t, amplitude: amplitude, phase: phase, origin: origin)
            let displaced = CGPoint(
                x: point.x + normal.dx * offset,
                y: point.y + normal.dy * offset
            )
            if index == 0 {
                path.move(to: displaced)
            } else {
                path.addLine(to: displaced)
            }
        }
        path.closeSubpath()
        return path
    }

    func restRect(in rect: CGRect) -> CGRect {
        rect.insetBy(dx: pad + insetAmount, dy: pad + insetAmount)
    }

    /// Perimeter parameter of the point on the resting silhouette closest
    /// to `point`, so the splash starts where the drag was released.
    static func origin(
        nearestTo point: CGPoint,
        in rect: CGRect,
        cornerRadius: CGFloat,
        pad: CGFloat
    ) -> CGFloat {
        let work = rect.insetBy(dx: pad, dy: pad)
        guard work.width > 1, work.height > 1 else { return 0 }

        let radius = min(cornerRadius, min(work.width, work.height) / 2)
        let samples = sample(
            RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: work),
            spacing: 4
        )
        guard !samples.isEmpty else { return 0 }

        var bestIndex = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, sample) in samples.enumerated() {
            let distance = hypot(sample.x - point.x, sample.y - point.y)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return CGFloat(bestIndex) / CGFloat(samples.count)
    }

    /// Traveling slosh around the rim, a finer counter-ripple, and a
    /// short splash at the release point. Displacement is capped so
    /// constructive interference cannot escape the view pad.
    static func displacement(
        t: CGFloat,
        amplitude: CGFloat,
        phase: CGFloat,
        origin: CGFloat
    ) -> CGFloat {
        let x = t - origin
        let theta = (x - phase) * 2 * CGFloat.pi
        let slosh = sin(theta * 2.25) + 0.18 * sin(theta * 4.5)
        let ripple = sin((x + phase * 0.55) * 2 * CGFloat.pi * 4)

        let wrapped = x - floor(x)
        let dist = min(wrapped, 1 - wrapped)
        let splash = exp(-dist * dist / 0.016) * max(0, 1 - phase * 1.7)

        let mixed = slosh * 0.7 + ripple * 0.22 + splash * 0.55
        return amplitude * max(-1.2, min(1.2, mixed))
    }

    private static func outwardNormal(
        at point: CGPoint,
        previous: CGPoint,
        next: CGPoint,
        center: CGPoint
    ) -> CGVector {
        var nx = next.y - previous.y
        var ny = previous.x - next.x
        let length = hypot(nx, ny)
        guard length > 0.0001 else { return .zero }
        nx /= length
        ny /= length
        if nx * (center.x - point.x) + ny * (center.y - point.y) > 0 {
            nx = -nx
            ny = -ny
        }
        return CGVector(dx: nx, dy: ny)
    }

    private static func sample(_ path: Path, spacing: CGFloat) -> [CGPoint] {
        var points: [CGPoint] = []
        var start = CGPoint.zero
        var current = CGPoint.zero
        var hasStart = false

        path.forEach { element in
            switch element {
            case .move(to: let point):
                start = point
                current = point
                hasStart = true
                if points.isEmpty {
                    points.append(point)
                }
            case .line(to: let point):
                appendLine(&points, from: current, to: point, spacing: spacing)
                current = point
            case .quadCurve(to: let point, control: let control):
                appendQuad(&points, from: current, control: control, to: point, spacing: spacing)
                current = point
            case .curve(to: let point, control1: let control1, control2: let control2):
                appendCubic(
                    &points,
                    from: current,
                    control1: control1,
                    control2: control2,
                    to: point,
                    spacing: spacing
                )
                current = point
            case .closeSubpath:
                if hasStart {
                    appendLine(&points, from: current, to: start, spacing: spacing)
                    current = start
                }
            }
        }

        if points.count >= 2,
           hypot(points[0].x - points[points.count - 1].x, points[0].y - points[points.count - 1].y) < 0.5 {
            points.removeLast()
        }
        return points
    }

    private static func appendLine(
        _ points: inout [CGPoint],
        from: CGPoint,
        to: CGPoint,
        spacing: CGFloat
    ) {
        let distance = hypot(to.x - from.x, to.y - from.y)
        let steps = max(1, Int(ceil(distance / max(spacing, 0.5))))
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            points.append(
                CGPoint(
                    x: from.x + (to.x - from.x) * t,
                    y: from.y + (to.y - from.y) * t
                )
            )
        }
    }

    private static func appendQuad(
        _ points: inout [CGPoint],
        from: CGPoint,
        control: CGPoint,
        to: CGPoint,
        spacing: CGFloat
    ) {
        let estimate = hypot(control.x - from.x, control.y - from.y)
            + hypot(to.x - control.x, to.y - control.y)
        let steps = max(3, Int(ceil(estimate / max(spacing, 0.5))))
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let one = 1 - t
            points.append(
                CGPoint(
                    x: one * one * from.x + 2 * one * t * control.x + t * t * to.x,
                    y: one * one * from.y + 2 * one * t * control.y + t * t * to.y
                )
            )
        }
    }

    private static func appendCubic(
        _ points: inout [CGPoint],
        from: CGPoint,
        control1: CGPoint,
        control2: CGPoint,
        to: CGPoint,
        spacing: CGFloat
    ) {
        let estimate = hypot(control1.x - from.x, control1.y - from.y)
            + hypot(control2.x - control1.x, control2.y - control1.y)
            + hypot(to.x - control2.x, to.y - control2.y)
        let steps = max(4, Int(ceil(estimate / max(spacing, 0.5))))
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let one = 1 - t
            let a = one * one * one
            let b = 3 * one * one * t
            let c = 3 * one * t * t
            let d = t * t * t
            points.append(
                CGPoint(
                    x: a * from.x + b * control1.x + c * control2.x + d * to.x,
                    y: a * from.y + b * control1.y + c * control2.y + d * to.y
                )
            )
        }
    }
}
