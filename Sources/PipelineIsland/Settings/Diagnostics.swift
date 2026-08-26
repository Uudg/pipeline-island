import AppKit

/// Prints everything that determines where — and whether — the island appears.
///
/// Exists because "the island didn't show up" has several unrelated causes and
/// no way to tell them apart from a screenshot: wrong display picked, notch not
/// detected, nothing actually running, or the resting state simply being too
/// subtle to notice against a black bezel.
///
/// Run with: PipelineIsland --diagnose
@MainActor
enum Diagnostics {
    static func run() {
        print("Pipeline Island — display diagnostics")
        print(String(repeating: "=", count: 52))
        print()

        // --- displays ---------------------------------------------------
        let screens = NSScreen.screens
        print("displays attached: \(screens.count)")
        for (index, screen) in screens.enumerated() {
            let isMain = screen == NSScreen.main
            let notch = screen.safeAreaInsets.top
            print("  [\(index)] \(screen.localizedName)")
            print("       size          \(Int(screen.frame.width))x\(Int(screen.frame.height)) at \(Int(screen.frame.origin.x)),\(Int(screen.frame.origin.y))")
            print("       scale         \(screen.backingScaleFactor)x")
            print("       safeAreaTop   \(notch)  \(notch > 0 ? "<- HAS A NOTCH" : "(no notch)")")
            print("       menu bar      \(screen.frame.origin == .zero ? "yes" : "no")")
            print("       keyboard focus\(isMain ? " yes" : " no")")
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                let cutout = screen.frame.width - left.width - right.width
                print("       cutout width  \(Int(cutout))pt")
            } else {
                print("       cutout width  n/a (auxiliary areas are nil)")
            }
        }
        print()

        // --- where the island will go -----------------------------------
        let preference = Preferences.shared.screenPreference
        print("screen preference: \(preference.rawValue)")
        guard let chosen = NotchGeometry.screen(for: preference) else {
            print("  !! no screen resolved — the island cannot be placed")
            return
        }
        print("  resolves to: \(chosen.localizedName)")

        let canvas = NotchGeometry.canvasSize(for: chosen, rows: 1)
        let placement = NotchGeometry.placement(on: chosen, size: canvas)
        print("  panel frame: \(Int(placement.frame.width))x\(Int(placement.frame.height))"
            + " at \(Int(placement.frame.origin.x)),\(Int(placement.frame.origin.y))")
        print("  hasNotch:    \(placement.hasNotch)")
        print("  notch size:  \(Int(placement.notchWidth))x\(Int(placement.notchHeight))")
        print()

        // --- what will actually be drawn --------------------------------
        let restingWidth = NotchGeometry.Width.resting(
            hasNotch: placement.hasNotch,
            notchWidth: placement.notchWidth
        )
        print("resting island width: \(Int(restingWidth))pt")
        if placement.hasNotch {
            print("  On a notched Mac the RESTING island is exactly the cutout: a small")
            print("  status dot on black, sitting on the black bezel. It is deliberately")
            print("  subtle and easy to miss. Hover the notch to expand it.")
        } else {
            print("  On a display without a notch the island is a \(Int(restingWidth))pt pill")
            print("  centred under the menu bar.")
        }
        print()

        // --- is there anything to show ----------------------------------
        print("token in keychain: \(TokenCache.shared.token() != nil ? "yes" : "NO — nothing will ever appear")")
        print()
        print("Note: the island only appears while a pipeline is RUNNING, or")
        print("briefly after one finishes. If nothing is running, an empty")
        print("notch is correct behaviour — check the menu bar icon instead.")
    }
}
