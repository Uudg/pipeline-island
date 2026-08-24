import AppKit

/// Where the island panel should sit, on which screen.
@MainActor
public enum NotchGeometry {
    /// Simulate a notch, for developing the notched layout with the lid closed.
    public static var simulateNotch = false
    static let simulatedNotchWidth: CGFloat = 190
    static let simulatedNotchHeight: CGFloat = 32
    /// Which display the island renders on.
    public enum ScreenPreference: String, Sendable, CaseIterable {
        /// The display that owns the menu bar (frame origin `.zero`).
        case primary
        /// The screen with keyboard focus (`NSScreen.main`).
        case main
        /// The built-in display, i.e. the only one that can actually have a notch.
        case builtIn
        /// The screen with a notch, if any is attached.
        case notched
    }

    public struct Placement: Sendable, Equatable {
        /// Panel frame in screen coordinates.
        public var frame: CGRect
        /// True when the panel is tucked under a real notch cutout.
        public var hasNotch: Bool
        /// Notch width in points, 0 when notchless.
        public var notchWidth: CGFloat
        /// Notch height (the menu-bar-thick cutout), 0 when notchless.
        public var notchHeight: CGFloat = 0
        /// The chosen screen's full frame, for debugging/logging.
        public var screenFrame: CGRect
        public var screenName: String
    }

    /// Island widths — the single source of truth.
    public enum Width {
        /// Hovered/expanded, both notched and notchless.
        public static let expanded: CGFloat = 620
        /// Resting on a notchless display: the stacked row list.
        public static let collapsed: CGFloat = 520
        /// Minimum resting width on a notched Mac, when the cutout is unusually narrow.
        public static let minimumNotch: CGFloat = 120

        /// Resting width for a screen.
        public static func resting(hasNotch: Bool, notchWidth: CGFloat) -> CGFloat {
            hasNotch ? max(notchWidth, minimumNotch) : collapsed
        }
    }

    /// Collapsed pill size, sized relative to the screen it lands on.
    public static func collapsedSize(for screen: NSScreen, rows: Int = 1) -> CGSize {
        let width = min(max(screen.frame.width * 0.16, 260), 520)
        let rowHeight: CGFloat = 32
        return CGSize(
            width: width,
            height: rowHeight * CGFloat(max(rows, 1)) + 20
                + (simulateNotch ? simulatedNotchHeight : screen.safeAreaInsets.top)
        )
    }

    /// Expanded panel size. Taller and wider; height grows with row count.
    public static func expandedSize(for screen: NSScreen, rows: Int) -> CGSize {
        let width = min(max(screen.frame.width * 0.24, 380), 620)
        let rowHeight: CGFloat = 46
        let chrome: CGFloat = 54
        let maxHeight = max(screen.visibleFrame.height * 0.6, 200)
        let height = min(chrome + CGFloat(max(rows, 1)) * rowHeight, maxHeight)
        return CGSize(width: width, height: height)
    }

    /// The window's fixed size — big enough for the largest state the island can
    /// reach, on this screen.
    ///
    /// **The window never resizes.** This is the fix for the expand "pop": the
    /// old design snapped the `NSWindow` 160pt wider in a single frame while
    /// SwiftUI sprang the content, so the pill visibly jumped sideways. AppKit
    /// window resizes are not animatable in step with a SwiftUI spring, and no
    /// amount of sequencing hides a hard jump that large.
    ///
    /// Instead the window is a fixed, transparent canvas sized to the worst case,
    /// and the *content* animates inside it. The background is clear and the
    /// panel ignores mouse events outside the drawn pill, so the extra area is
    /// invisible and non-interactive.
    public static func canvasSize(for screen: NSScreen, rows: Int) -> CGSize {
        let expanded = expandedSize(for: screen, rows: rows)
        let collapsed = collapsedSize(for: screen, rows: 4)
        let notchBand = simulateNotch ? simulatedNotchHeight : screen.safeAreaInsets.top
        return CGSize(
            width: max(expanded.width, collapsed.width, Width.expanded),
            height: max(expanded.height + notchBand, collapsed.height)
        )
    }

    /// Pick the display to render on.
    public static func screen(for preference: ScreenPreference) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        switch preference {
        case .primary:
            return screens.first(where: { $0.frame.origin == .zero })
                ?? NSScreen.main
                ?? screens.first
        case .main:
            return NSScreen.main ?? screens.first
        case .builtIn:
            return screens.first(where: isBuiltIn) ?? NSScreen.main ?? screens.first
        case .notched:
            return screens.first(where: { $0.safeAreaInsets.top > 0 })
                ?? NSScreen.main
                ?? screens.first
        }
    }

    /// A built-in display reports a notch, or identifies as the Apple panel.
    private static func isBuiltIn(_ screen: NSScreen) -> Bool {
        if screen.safeAreaInsets.top > 0 { return true }
        let name = screen.localizedName.lowercased()
        return name.contains("built-in") || name.contains("liquid retina")
    }

    /// Compute the panel frame for a screen and a content size.
    public static func placement(
        on screen: NSScreen,
        size: CGSize
    ) -> Placement {
        let frame = screen.frame
        let notchHeight = simulateNotch ? simulatedNotchHeight : screen.safeAreaInsets.top
        let hasNotch = notchHeight > 0

        var notchWidth: CGFloat = simulateNotch ? simulatedNotchWidth : 0
        if !simulateNotch,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            notchWidth = max(frame.width - left.width - right.width, 0)
        }

        var originX = frame.midX - size.width / 2
        let originY: CGFloat

        if hasNotch {
            originY = frame.maxY - size.height
            originX = frame.midX - size.width / 2
        } else {
            let gap: CGFloat = 6
            originY = screen.visibleFrame.maxY - size.height - gap
        }

        return Placement(
            frame: CGRect(x: originX.rounded(), y: originY.rounded(),
                          width: size.width.rounded(), height: size.height.rounded()),
            hasNotch: hasNotch,
            notchWidth: notchWidth,
            notchHeight: notchHeight,
            screenFrame: frame,
            screenName: screen.localizedName
        )
    }
}
