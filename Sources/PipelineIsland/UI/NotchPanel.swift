import AppKit
import SwiftUI

/// One motion vocabulary for the whole island.
public enum Motion {
    /// Island arriving on screen.
    public static let entry = Animation.spring(duration: 0.42, bounce: 0.30)
    /// Island leaving.
    public static let exit = Animation.easeInOut(duration: 0.44)

    /// Hover expansion.
    public static let expand = Animation.spring(duration: 0.40, bounce: 0.26)
    /// Hover collapse — slightly faster and flatter than the expand.
    public static let collapse = Animation.spring(duration: 0.32, bounce: 0.12)
    /// Content changing inside the pill (status flips, job dots appearing).
    public static let content = Animation.spring(duration: 0.34, bounce: 0.18)

    /// Window alpha ramps, in seconds.
    public static let fadeIn: TimeInterval = 0.22
    /// Longer than `exit` on purpose: the shape must finish moving while still visible.
    public static let fadeOut: TimeInterval = 0.52
    /// How long to wait after a collapse spring before shrinking the window.
    public static let collapseSettle: TimeInterval = 0.36
}

/// A borderless, non-activating panel pinned to the top of the chosen screen.
final class IslandPanel: NSPanel {
    /// Borderless windows are not key by default, which would break hover and clicks.
    override var canBecomeKey: Bool { true }
    /// Never main — this is an accessory, it must not own the menu bar.
    override var canBecomeMain: Bool { false }

}

/// The content view: transparent outside the drawn pill.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    /// Height of the region that should accept the mouse, measured from the top of the window.
    var interactiveHeight: CGFloat = 0
    /// Width of that region, centred horizontally.
    var interactiveWidth: CGFloat = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactiveHeight > 0, interactiveWidth > 0 else {
            return super.hitTest(point)
        }
        let top = bounds.maxY
        let left = bounds.midX - interactiveWidth / 2
        let islandRect = CGRect(
            x: left,
            y: top - interactiveHeight,
            width: interactiveWidth,
            height: interactiveHeight
        )
        guard islandRect.contains(point) else { return nil }
        return super.hitTest(point)
    }
}

/// Owns the panel, its hosting view, and its placement across screen changes.
@MainActor
public final class NotchPanelController {
    private let panel: IslandPanel
    private let model: IslandModel
    private let hostingView: PassthroughHostingView<AnyView>
    private let onOpen: (Pipeline) -> Void
    private let onQuit: () -> Void

    /// Which display to render on.
    public var screenPreference: NotchGeometry.ScreenPreference = .primary {
        didSet { reposition() }
    }

    private var currentPlacement: NotchGeometry.Placement?
    private var observers: [NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?

    /// Intended visibility, which differs from `panel.isVisible` mid-fade.
    private var isShown = false
    private var fadeWork: DispatchWorkItem?
    private var resizeWork: DispatchWorkItem?

    public init(
        model: IslandModel,
        onOpen: @escaping (Pipeline) -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.model = model
        self.onOpen = onOpen
        self.onQuit = onQuit

        panel = IslandPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Panel config per CLAUDE.md.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.animationBehavior = .none
        // Never pin the panel — paint-time colours follow the effective appearance.
        panel.appearance = nil

        hostingView = PassthroughHostingView(rootView: AnyView(EmptyView()))
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        reposition()
        applyAppearancePreference()
        updateRootView()
        observeScreenChanges()
        observeAppearanceChanges()
    }

    /// Rebuild the hosting tree so Theme Auto/Light/Dark takes effect.
    /// Never pins `NSApp.appearance` or `panel.appearance`. The override
    /// lives on the hosting view so paint-time colours see the right scheme.
    public func applyAppearancePreference() {
        NSApp.appearance = nil
        panel.appearance = nil
        switch Preferences.shared.appearance {
        case .auto:
            hostingView.appearance = nil
        case .light:
            hostingView.appearance = NSAppearance(named: .aqua)
        case .dark:
            hostingView.appearance = NSAppearance(named: .darkAqua)
        }
        updateRootView()
    }

    /// Drop the notification observers.
    public func invalidate() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        appearanceObservation?.invalidate()
        appearanceObservation = nil
    }

    /// Corner treatment differs under a cutout, so rebuild the root view when it changes.
    private func updateRootView() {
        let scheme = Preferences.shared.appearance.preferredColorScheme
        hostingView.rootView = AnyView(
            IslandView(
                model: model,
                hasNotch: currentPlacement?.hasNotch ?? false,
                notchHeight: currentPlacement?.notchHeight ?? 0,
                notchWidth: currentPlacement?.notchWidth ?? 0,
                onOpen: onOpen,
                onQuit: onQuit,
                onHoverChange: { [weak self] hovering in
                    self?.setExpanded(hovering)
                }
            )
            .preferredColorScheme(scheme)
        )
    }

    // MARK: - Visibility

    /// Cross-fade the panel in and out instead of popping it.
    public func setVisible(_ visible: Bool) {
        guard visible != isShown else { return }
        isShown = visible

        fadeWork?.cancel()

        if visible {
            model.isExpanded = false
            applyFrame()

            panel.alphaValue = 0
            panel.orderFrontRegardless()

            model.isLeaving = false
            model.isOnScreen = false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                withAnimation(Motion.entry) { self.model.isOnScreen = true }
            }

            updateInteractiveRegion()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.fadeIn
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else {
            model.isLeaving = true
            withAnimation(Motion.exit) { model.isOnScreen = false }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.fadeOut
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard let self, !self.isShown else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    public var isVisible: Bool { panel.isVisible }

    /// Panel frame in screen coordinates.
    public var frame: CGRect { panel.frame }

    public var placement: NotchGeometry.Placement? { currentPlacement }

    // MARK: - Expansion

    /// Expand or collapse.
    public func setExpanded(_ expanded: Bool) {
        guard expanded != model.isExpanded else { return }
        if expanded { Haptics.expanded() }
        withAnimation(expanded ? Motion.expand : Motion.collapse) {
            model.isExpanded = expanded
        }
        updateInteractiveRegion()
    }

    /// Tell the hosting view how much of the canvas the island actually covers.
    public func refreshInteractiveRegion() { updateInteractiveRegion() }

    private func updateInteractiveRegion() {
        let hasNotch = currentPlacement?.hasNotch ?? false
        let notchWidth = currentPlacement?.notchWidth ?? 0
        let notchHeight = currentPlacement?.notchHeight ?? 0

        if model.isExpanded {
            hostingView.interactiveWidth = NotchGeometry.Width.expanded
            hostingView.interactiveHeight = panel.frame.height
            return
        }

        if hasNotch {
            hostingView.interactiveWidth = NotchGeometry.Width.resting(hasNotch: true, notchWidth: notchWidth)
            hostingView.interactiveHeight = notchHeight + 20
            return
        }

        let rows = max(model.collapsedPipelines.count, 1)
        let rowHeight: CGFloat = 32
        let chrome: CGFloat = 20
        hostingView.interactiveWidth = NotchGeometry.Width.collapsed
        hostingView.interactiveHeight = rowHeight * CGFloat(rows) + chrome
    }

    // MARK: - Placement

    /// Recompute the canvas frame for the current screen.
    public func reposition() {
        applyFrame()
    }

    private func applyFrame() {
        guard let screen = NotchGeometry.screen(for: screenPreference) else { return }

        let size = NotchGeometry.canvasSize(for: screen, rows: 8)
        let placement = NotchGeometry.placement(on: screen, size: size)
        let notchChanged = placement.hasNotch != currentPlacement?.hasNotch
            || placement.notchHeight != currentPlacement?.notchHeight
            || placement.notchWidth != currentPlacement?.notchWidth
        currentPlacement = placement

        if panel.frame != placement.frame {
            panel.setFrame(placement.frame, display: true)
        }
        if notchChanged { updateRootView() }
    }

    /// Lid open/close and monitor sleep move the panel between displays mid-session.
    private func observeScreenChanges() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        })

        // A space switch can leave a stationary panel stranded on some setups.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        })
    }

    /// OS Light/Dark flips must repaint the island without a relaunch.
    private func observeAppearanceChanges() {
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.panel.appearance = nil
                self.hostingView.needsDisplay = true
                self.updateRootView()
            }
        }
    }
}
