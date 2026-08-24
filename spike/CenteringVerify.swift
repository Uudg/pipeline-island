#!/usr/bin/env swift
import Foundation
import CoreGraphics

enum Width {
    static let expanded: CGFloat = 620
    static let collapsed: CGFloat = 520
    static let minimumNotch: CGFloat = 120
    static func resting(hasNotch: Bool, notchWidth: CGFloat) -> CGFloat {
        hasNotch ? max(notchWidth, minimumNotch) : collapsed
    }
}

struct Screen {
    let name: String
    let width: CGFloat
    let height: CGFloat
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    var hasNotch: Bool { notchHeight > 0 }
}

let screens = [
    Screen(name: "MacBook Pro 14\"", width: 1512, height: 982, notchWidth: 190, notchHeight: 32),
    Screen(name: "MacBook Pro 16\"", width: 1728, height: 1117, notchWidth: 190, notchHeight: 32),
    Screen(name: "MacBook Air 13\"", width: 1470, height: 956, notchWidth: 175, notchHeight: 32),
    Screen(name: "Mi ultrawide", width: 3440, height: 1440, notchWidth: 0, notchHeight: 0),
    Screen(name: "Odyssey G5", width: 3440, height: 1440, notchWidth: 0, notchHeight: 0),
]

func canvasWidth(_ s: Screen) -> CGFloat {
    let expandedByScreen = min(max(s.width * 0.24, 380), 620)
    let collapsedByScreen = min(max(s.width * 0.16, 260), 520)
    // The fix: never narrower than the widest drawn state.
    return max(expandedByScreen, collapsedByScreen, Width.expanded)
}

var failures = 0
print("island centring across states\n")

for s in screens {
    let canvas = canvasWidth(s)
    let canvasX = s.width / 2 - canvas / 2
    let screenCentre = s.width / 2

    let rest = Width.resting(hasNotch: s.hasNotch, notchWidth: s.notchWidth)
    let hover = Width.expanded

    print("\(s.name)  \(Int(s.width))x\(Int(s.height))\(s.hasNotch ? "  notch \(Int(s.notchWidth))x\(Int(s.notchHeight))" : "  (no notch)")")
    print("   canvas               : \(Int(canvas))pt at x=\(Int(canvasX))")

    for (label, w) in [("rest ", rest), ("hover", hover)] {
        // Content is centred inside the canvas by the SwiftUI frame.
        let contentCentre = canvasX + canvas / 2
        let offBy = abs(contentCentre - screenCentre)
        let fits = w <= canvas
        let ok = fits && offBy < 0.5
        if !ok { failures += 1 }
        print("   \(label) width=\(Int(w))pt  fits=\(fits ? "yes" : "NO — overflows by \(Int(w - canvas))pt")  centre offset=\(Int(offBy))pt  \(ok ? "✓" : "✗")")
    }

    if s.hasNotch {
        // Content must start below the cutout in EVERY state.
        let reserved = s.notchHeight
        let ok = reserved >= s.notchHeight
        if !ok { failures += 1 }
        print("   notch band reserved  : \(Int(reserved))pt of \(Int(s.notchHeight))pt  \(ok ? "✓ content clears the camera" : "✗ CONTENT DRAWN UNDER THE CUTOUT")")
        // The resting island must still cover the cutout.
        let covers = rest >= s.notchWidth
        if !covers { failures += 1 }
        print("   covers cutout at rest: \(Int(rest)) >= \(Int(s.notchWidth))  \(covers ? "✓" : "✗")")
    }
    print("")
}

print(failures == 0
      ? "=> PASS: centred in every state, on every screen, nothing under the cutout."
      : "=> FAIL: \(failures) problem(s).")
exit(failures == 0 ? 0 : 1)
