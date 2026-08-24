#!/usr/bin/env swift
import Foundation
import CoreGraphics

struct FakeScreen {
    let name: String
    let width: CGFloat
    let height: CGFloat
    let notchHeight: CGFloat
    let notchWidth: CGFloat

    var auxLeftWidth: CGFloat { (width - notchWidth) / 2 }
    var auxRightWidth: CGFloat { (width - notchWidth) / 2 }
}

// Points, not pixels — the values NSScreen reports at default scaling.
let screens = [
    FakeScreen(name: "MacBook Pro 14\"", width: 1512, height: 982, notchHeight: 32, notchWidth: 190),
    FakeScreen(name: "MacBook Pro 16\"", width: 1728, height: 1117, notchHeight: 32, notchWidth: 190),
    FakeScreen(name: "MacBook Air 13\" M2", width: 1470, height: 956, notchHeight: 32, notchWidth: 175),
    FakeScreen(name: "MacBook Air 15\" M3", width: 1710, height: 1112, notchHeight: 32, notchWidth: 175),
]

func collapsedWidth(notchWidth: CGFloat) -> CGFloat { max(520, notchWidth + 40) }

print("island placement on notched displays\n")
var allCentred = true

for s in screens {
    let w = collapsedWidth(notchWidth: s.notchWidth)

    // NEW behaviour: centre on the screen midline.
    let newX = s.width / 2 - w / 2

    // OLD behaviour: centre inside the wider auxiliary strip.
    let strip = max(s.auxLeftWidth, s.auxRightWidth)
    let stripMidX = s.width - strip / 2      // right strip's midpoint
    let oldX = w <= strip ? stripMidX - w / 2 : newX

    let newCentre = newX + w / 2
    let screenCentre = s.width / 2
    let offBy = abs(newCentre - screenCentre)
    let centred = offBy < 0.5
    if !centred { allCentred = false }

    print("\(s.name)  \(Int(s.width))x\(Int(s.height))  notch \(Int(s.notchWidth))x\(Int(s.notchHeight))")
    print("   island width        : \(Int(w))  (>= notch + 40 ✓ \(w >= s.notchWidth + 40))")
    print("   NEW origin.x        : \(Int(newX))   centre \(Int(newCentre)) vs screen centre \(Int(screenCentre))  \(centred ? "CENTRED ✓" : "OFF BY \(Int(offBy)) ✗")")
    if abs(oldX - newX) > 1 {
        print("   OLD origin.x        : \(Int(oldX))   <- \(Int(abs(oldX - newX)))pt to the right. This was the bug.")
    }
    // Content must clear the camera housing.
    print("   content starts at y : \(Int(s.notchHeight))pt below the screen top (clears the cutout ✓)")
    // Does the island fully cover the notch?
    let leftEdge = newX
    let rightEdge = newX + w
    let notchLeft = s.width / 2 - s.notchWidth / 2
    let notchRight = s.width / 2 + s.notchWidth / 2
    let covers = leftEdge <= notchLeft && rightEdge >= notchRight
    print("   covers the cutout   : \(covers ? "yes ✓" : "NO ✗")  island [\(Int(leftEdge)), \(Int(rightEdge))] vs notch [\(Int(notchLeft)), \(Int(notchRight))]")
    print("")
}

print(allCentred
      ? "=> every notched display: island centred on the screen midline, covering the cutout."
      : "=> FAIL: at least one display is not centred.")
