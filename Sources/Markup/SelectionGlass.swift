import AppKit
import SwiftUI

/// Glass that never intercepts mouse events, so the view underneath keeps
/// receiving the drag while the pane floats above it.
final class PassthroughGlassView: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// Hosts a selection's Liquid Glass pane without eating mouse events.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

final class SelectionGlassTuning: ObservableObject {
    static let wavePad: CGFloat = 14
    static let waveDuration: TimeInterval = 0.98

    @Published var cornerRadius: CGFloat = LiquidGlassSelectionRenderer.cornerRadiusMax
    @Published var waveOrigin: CGFloat = 0
    @Published var wavePeak: CGFloat = 0
    @Published var waveStartedAt: Date?

    var isWaving: Bool { waveStartedAt != nil }

    func startWave(origin: CGFloat, peak: CGFloat) {
        waveOrigin = origin
        wavePeak = peak
        waveStartedAt = Date()
    }

    func stopWave() {
        waveStartedAt = nil
        wavePeak = 0
    }

    func endWaveIfNeeded() {
        guard let start = waveStartedAt else { return }
        if Date().timeIntervalSince(start) >= Self.waveDuration {
            stopWave()
        }
    }

    func wave(at now: Date) -> (amplitude: CGFloat, phase: CGFloat) {
        guard let start = waveStartedAt else { return (0, 0) }
        let time = max(0, now.timeIntervalSince(start))
        guard time < Self.waveDuration else { return (0, 0) }

        let progress = time / Self.waveDuration
        let decay = pow(1 - progress, 1.3)
        let phase = (1 - pow(1 - progress, 1.45)) * 1.08
        return (wavePeak * decay, phase)
    }
}

/// Clear Liquid Glass fitted to a selection. On the live screen the system
/// glass samples the real desktop behind the window — this is the whole
/// point of 2.0's live mode. The silhouette is a continuous rounded rect at
/// rest; on release it becomes a LiquidWaveShape so the glass bevels travel
/// with the rim wave.
struct SelectionGlassPane: View {
    @ObservedObject var tuning: SelectionGlassTuning

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !tuning.isWaving)) { context in
            let wave = tuning.wave(at: context.date)
            pane(amplitude: wave.amplitude, phase: wave.phase)
        }
    }

    private func pane(amplitude: CGFloat, phase: CGFloat) -> some View {
        let shape = LiquidWaveShape(
            cornerRadius: tuning.cornerRadius,
            pad: SelectionGlassTuning.wavePad,
            amplitude: amplitude,
            phase: phase,
            origin: tuning.waveOrigin
        )

        return Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassEffect(.clear, in: shape)
            .mask {
                GlassClearFadeMask(shape: shape)
            }
            .overlay {
                shape.fill(Color.white.opacity(LiquidGlassSelectionRenderer.centerFill))
            }
            .allowsHitTesting(false)
    }
}

/// Stronger at the outer silhouette, then a short falloff to a faint
/// interior. The glass shape stays a filled path (outer bevels only);
/// this mask only controls how visible that glass is.
private struct GlassClearFadeMask: View {
    var shape: LiquidWaveShape

    var body: some View {
        GeometryReader { proxy in
            let shortest = max(
                1,
                min(proxy.size.width, proxy.size.height) - SelectionGlassTuning.wavePad * 2
            )
            let melt = LiquidGlassSelectionRenderer.meltDepth(shortest: shortest)
            let centerPunch = 1 - LiquidGlassSelectionRenderer.centerGlass

            if shortest < melt * 2 + 8 {
                shape.fill(Color.white)
            } else {
                shape.fill(Color.white)
                    .overlay {
                        shape
                            .inset(by: melt)
                            .fill(Color.white.opacity(centerPunch))
                            .blur(radius: melt * 0.28)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
            }
        }
    }
}

extension NSImage {
    func bestCGImage() -> CGImage {
        var rect = NSRect(origin: .zero, size: size)
        if let cgImage = cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return cgImage
        }

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(size.width)),
            pixelsHigh: max(1, Int(size.height)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }
}
