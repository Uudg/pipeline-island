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

    private let hasNotch: Bool
    private var frameIndex = 0
    private var timer: Timer?
    private var started = Date()
    private var hostingView: NSHostingView<AnyView>?

    /// Canvas size.
    ///
    /// The notched stage renders at true 16" MacBook width (1728pt) so the
    /// panel covers the same fraction of the frame as it does on real
    /// hardware — at 900pt it took 69% of the width and swallowed the menu
    /// bar. ffmpeg downscales for the GIF.
    private var size: CGSize {
        hasNotch ? CGSize(width: 1728, height: 300) : CGSize(width: 900, height: 320)
    }
    private let scale: CGFloat = 2

    init(
        model: IslandModel,
        outputDirectory: URL,
        hasNotch: Bool = false,
        fps: Int = 20,
        duration: TimeInterval = 18
    ) {
        self.model = model
        self.outputDirectory = outputDirectory
        self.hasNotch = hasNotch
        self.fps = fps
        self.duration = duration
    }

    func start() {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let stage = DemoStage(model: model, hasNotch: hasNotch, width: size.width, height: size.height)
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
    /// Draw a MacBook top bezel with a real cutout, rather than a plain strip.
    var hasNotch: Bool = false

    var width: CGFloat = 900
    var height: CGFloat = 320
    private var notchWidth: CGFloat { hasNotch ? 185 : 0 }
    private var menuBarHeight: CGFloat { hasNotch ? 32 : 28 }

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

            if hasNotch {
                notchedMenuBar
            } else {
                plainMenuBar
            }

            // The island itself, at the top centre where it really sits.
            IslandView(
                model: model,
                hasNotch: hasNotch,
                notchHeight: hasNotch ? menuBarHeight : 0,
                notchWidth: hasNotch ? notchWidth : 0,
                onOpen: { _ in },
                onQuit: {}
            )
            .frame(width: width, height: height - 28, alignment: .top)
        }
        .frame(width: width, height: height)
    }

    /// Menu bar for a display without a cutout.
    private var plainMenuBar: some View {
        HStack {
            Spacer()
            Text("Fri 14:52")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.trailing, 14)
        }
        .frame(height: menuBarHeight)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.25))
    }

    /// Menu bar split around a physical cutout, as on a MacBook.
    ///
    /// The menu items sit in the auxiliary strips either side of the notch,
    /// which is what makes the island reading as "part of the hardware" land.
    private var notchedMenuBar: some View {
        HStack(spacing: 0) {
            // Left strip: app menus.
            HStack(spacing: 14) {
                Text("").font(.system(size: 13))
                Text("Xcode").font(.system(size: 12, weight: .semibold))
                Text("File").font(.system(size: 12))
                Text("Edit").font(.system(size: 12))
                Spacer()
            }
            .foregroundStyle(.white.opacity(0.72))
            .padding(.leading, 16)
            .frame(width: (width - notchWidth) / 2)

            // The cutout itself: opaque hardware.
            Color.black.frame(width: notchWidth)

            // Right strip: status items and clock.
            HStack(spacing: 13) {
                Spacer()
                Image(systemName: "wifi")
                Image(systemName: "battery.75")
                Text("Fri 14:52").font(.system(size: 12))
            }
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.72))
            .padding(.trailing, 16)
            .frame(width: (width - notchWidth) / 2)
        }
        .frame(height: menuBarHeight)
        .background(Color.black.opacity(0.28))
    }
}
