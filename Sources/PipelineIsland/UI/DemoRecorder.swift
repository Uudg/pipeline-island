import AppKit
import SwiftUI

/// Records the island to a PNG sequence for the README demo.
///
/// Captures the app's own view rather than the screen, so it needs no Screen
/// Recording permission and picks up nothing else on the desktop. Frames are
/// composited onto a synthetic menu bar so the island reads as living at the
/// top of a display.
///
/// Driven by `--record <dir>`; `scripts/make-demo.sh` turns the frames into a
/// GIF and an MP4.
@MainActor
final class DemoRecorder {
    private let model: IslandModel
    private let outputDirectory: URL
    private let fps: Int
    private let duration: TimeInterval

    private var frameIndex = 0
    private var timer: Timer?
    private var started = Date()
    private var hostingView: NSHostingView<AnyView>?

    /// Canvas size. 2x for a crisp result on a retina README.
    private let size = CGSize(width: 900, height: 320)
    private let scale: CGFloat = 2

    init(model: IslandModel, outputDirectory: URL, fps: Int = 25, duration: TimeInterval = 22) {
        self.model = model
        self.outputDirectory = outputDirectory
        self.fps = fps
        self.duration = duration
    }

    func start() {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let stage = DemoStage(model: model)
        let host = NSHostingView(rootView: AnyView(stage))
        host.frame = CGRect(origin: .zero, size: size)

        // The view must be in a window for SwiftUI to run its animations; an
        // offscreen window is enough and never appears on screen.
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.alphaValue = 0
        window.orderFront(nil)
        hostingView = host

        // The panel controller normally drives this; without it the island
        // stays at its entry scale with zero opacity and nothing is captured.
        model.isOnScreen = true

        started = Date()
        let interval = 1.0 / Double(fps)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.captureFrame() }
        }
        print("recording \(Int(duration))s at \(fps)fps -> \(outputDirectory.path)")
    }

    private func captureFrame() {
        guard let host = hostingView else { return }

        if Date().timeIntervalSince(started) >= duration {
            finish()
            return
        }

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let name = String(format: "frame-%05d.png", frameIndex)
        try? png.write(to: outputDirectory.appendingPathComponent(name))
        frameIndex += 1
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        print("wrote \(frameIndex) frames")
        exit(0)
    }
}

/// The backdrop the island is composited onto for the demo.
///
/// A muted desktop gradient with a menu bar strip and a notch cutout, so the
/// recording reads as "this lives at the top of your screen" without showing
/// anyone's actual desktop.
private struct DemoStage: View {
    @Bindable var model: IslandModel

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [
                    Color(red: 0.11, green: 0.12, blue: 0.16),
                    Color(red: 0.06, green: 0.07, blue: 0.09),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Menu bar strip, with the usual clock on the right so the scale
            // reads correctly.
            HStack {
                Spacer()
                Text("Fri 14:52")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.trailing, 14)
            }
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.25))

            // The island itself, at the top centre where it really sits.
            IslandView(
                model: model,
                hasNotch: false,
                notchHeight: 0,
                notchWidth: 0,
                onOpen: { _ in },
                onQuit: {}
            )
            .frame(width: 900, height: 292, alignment: .top)
        }
        .frame(width: 900, height: 320)
    }
}
