# Notes on the UI

## There's no Dynamic Island API

The notch is screen geometry, nothing more. Three properties do the work:

```swift
NSScreen.main?.safeAreaInsets.top      // notch height, 0 without one
NSScreen.main?.auxiliaryTopLeftArea    // strip to the left of the cutout
NSScreen.main?.auxiliaryTopRightArea   // and to the right
```

The window is a borderless non-activating `NSPanel` at `.statusBar + 1`, with
`LSUIElement` set so there's no Dock icon. Non-activating matters: clicking the
island mustn't pull focus out of your editor.

## The no-notch layout is the primary one

Measured on the machine this was built on:

```
[0] external   3440x1440   safeAreaTop: 0.0   no notch
[1] external   3440x1440   safeAreaTop: 0.0   no notch
```

Lid closed, two external monitors, zero notches. An app built notch-first would
be invisible for most of the working day, so the notchless pill is the main path
and the notch variant is the special case.

## Never resize the window mid-animation

The single thing that makes it feel right. Resizing an `NSWindow` in the same
pass as a SwiftUI animation re-lays-out the hosting view halfway through the
spring, and the result pops instead of moving.

So the window is a fixed, oversized, transparent canvas that never changes size.
The *content* animates inside it. Verified across a full show/hide cycle: the
frame stays at 620×422 from entry to exit.

The consequence is that most of the window is empty space, so
`PassthroughHostingView.hitTest` returns `nil` outside the drawn island —
otherwise it silently swallows clicks across a 620×422 region of your screen.
That bug did happen: the island was eating clicks aimed at a window underneath it.

## Motion

Every spring lives in one `Motion` enum so the thing moves like a single object.

```swift
entry    = .spring(duration: 0.42, bounce: 0.30)
exit     = .easeInOut(duration: 0.44)
expand   = .spring(duration: 0.40, bounce: 0.26)
collapse = .spring(duration: 0.32, bounce: 0.12)
content  = .spring(duration: 0.34, bounce: 0.18)

fadeIn   = 0.22   // shorter than entry: opaque while the shape settles
fadeOut  = 0.52   // longer than exit: still visible while the shape moves
```

That fade/animation relationship is load-bearing. The first version had a 0.20s
fade under a 0.26s exit spring, so opacity hit zero while the shape was still
moving — the exit animation ran every time and was never once seen. It looked
like the island simply blinked out.

## Visual grammar

Borrowed from GitLab's own pipeline graph, so there's nothing to learn: one dot
per job, grouped by stage, thin connectors between stages. Colour is the job
status, pending jobs are hollow, running jobs pulse.

The dots appear in the collapsed pill too — seeing what's running shouldn't
require a hover.

## Haptics

| moment | pattern |
|---|---|
| pipeline starts | `.alignment` |
| succeeds | `.levelChange` |
| fails | `.generic` ×2 |
| hover expands | `.alignment` |

Restraint is most of the design here. The app polls every 5–10 seconds, so only
real transitions tap; job-level progress inside a running pipeline is silent;
several pipelines finishing in one poll produce one tap, not several; and the
first poll after launch is silent, or starting the app would buzz for everything
already running.
