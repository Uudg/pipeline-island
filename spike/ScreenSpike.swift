#!/usr/bin/env swift
import AppKit

print("screens: \(NSScreen.screens.count)")
print("")
for (i, s) in NSScreen.screens.enumerated() {
    let isMain = s == NSScreen.main
    let name = s.localizedName
    let f = s.frame
    let inset = s.safeAreaInsets
    let hasNotch = inset.top > 0
    print("[\(i)] \(name)\(isMain ? "   ← NSScreen.main" : "")")
    print("     frame:        \(Int(f.width))x\(Int(f.height)) @ (\(Int(f.origin.x)),\(Int(f.origin.y)))")
    print("     backingScale: \(s.backingScaleFactor)")
    print("     safeAreaTop:  \(inset.top)   => \(hasNotch ? "NOTCHED" : "NO NOTCH")")
    if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
        print("     auxLeft:      \(Int(l.width))x\(Int(l.height))")
        print("     auxRight:     \(Int(r.width))x\(Int(r.height))")
        print("     notchWidth:   ~\(Int(f.width - l.width - r.width))pt")
    } else {
        print("     aux areas:    nil (no notch cutout)")
    }
    print("")
}

let notched = NSScreen.screens.filter { $0.safeAreaInsets.top > 0 }
let mainHasNotch = (NSScreen.main?.safeAreaInsets.top ?? 0) > 0
print("─────────────────────────────────────────")
print("notched displays attached: \(notched.count) of \(NSScreen.screens.count)")
print("NSScreen.main has notch:   \(mainHasNotch)")
print("")
print(mainHasNotch
  ? "=> NOTCH PATH is primary on this setup."
  : "=> FALLBACK PATH is primary on this setup. The no-notch pill is NOT an edge case.")
