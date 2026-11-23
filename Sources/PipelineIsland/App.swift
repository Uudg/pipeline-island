import AppKit
import SwiftUI

/// Application entry point.
@main
enum PipelineIslandApp {
    @MainActor
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)

        let arguments = CommandLine.arguments
        let command = arguments.count > 1 ? arguments[1] : "run"

        switch command {
        case "store", "delete", "verify", "migrate":
            CommandLineHarness.run(command: command, arguments: arguments)
        case "run":
            launchUI()
        case "--snapshot":
            let out = arguments.count > 2 ? arguments[2] : "island.png"
            launchUI(snapshotPath: out)
        case "--snapshot-fail":
            let outFail = arguments.count > 2 ? arguments[2] : "island-fail.png"
            launchUI(snapshotPath: outFail, snapshotMulti: true, snapshotFailure: true)
        case "--snapshot-notch":
            // Render the NOTCHED layout (simulated cutout) for review.
            NotchGeometry.simulateNotch = true
            let outNotch = arguments.count > 2 ? arguments[2] : "island-notch.png"
            launchUI(snapshotPath: outNotch, snapshotMulti: true, snapshotNotch: true)
        case "--snapshot-multi":
            let outMulti = arguments.count > 2 ? arguments[2] : "island-multi.png"
            launchUI(snapshotPath: outMulti, snapshotMulti: true)
        case "--diagnose":
            Diagnostics.run()
            exit(0)
        case "--login-status":
            // Report SMAppService state, for verifying launch-at-login works
            // from inside a real bundle.
            LaunchAtLogin.printStatus()
            exit(0)
        case "--record-notch":
            NotchGeometry.simulateNotch = true
            let notchDir = arguments.count > 2 ? arguments[2] : "demo-frames-notch"
            launchUI(demo: true, recordTo: notchDir, recordNotch: true)
        case "--record":
            // Record the island to a PNG sequence for the README demo.
            NotchGeometry.simulateNotch = true
            let dir = arguments.count > 2 ? arguments[2] : "demo-frames"
            launchUI(demo: true, recordTo: dir)
        case "--demo-notch":
            NotchGeometry.simulateNotch = true
            launchUI(demo: true)
        case "--demo":
            launchUI(demo: true)
        case "--verify-ui":
            launchUI(verifyOnly: true)
        default:
            print("usage: PipelineIsland [run | --demo | --demo-notch | --record <dir> | --record-notch <dir> | --verify-ui | --snapshot <path> | store <PAT> | migrate | delete | verify]")
            exit(1)
        }
    }

    @MainActor
    private static func launchUI(verifyOnly: Bool = false, snapshotPath: String? = nil, demo: Bool = false, recordTo: String? = nil, recordNotch: Bool = false, snapshotMulti: Bool = false, snapshotFailure: Bool = false, snapshotNotch: Bool = false) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Never pin the app — Theme Auto/Light/Dark is content-scoped only.
        app.appearance = nil
        // Accessory apps have no menu bar, but ⌘X/C/V/A in text fields are
        // routed through the main menu's key equivalents — so install one.
        app.mainMenu = editOnlyMainMenu()

        let delegate = AppDelegate(verifyOnly: verifyOnly, snapshotPath: snapshotPath, demo: demo, recordTo: recordTo, recordNotch: recordNotch, snapshotMulti: snapshotMulti, snapshotFailure: snapshotFailure, snapshotNotch: snapshotNotch)
        app.delegate = delegate
        app.run()
    }

    @MainActor
    private static func editOnlyMainMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem()
        editItem.submenu = edit
        let menu = NSMenu()
        menu.addItem(NSMenuItem()) // app menu slot
        menu.addItem(editItem)
        return menu
    }
}

/// Owns the monitor, the model and the panel for the lifetime of the process.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = IslandModel()
    private let monitor = PipelineMonitor(
        client: GitLabClient(endpoint: GitLabClient.endpoint(for: Preferences.shared.host))
    )
    private var panelController: NotchPanelController?

    /// Stream consumer.
    private var streamTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    private var visibilityTask: Task<Void, Never>?

    private let verifyOnly: Bool
    private let snapshotPath: String?
    private let demo: Bool
    private let recordTo: String?
    private let recordNotch: Bool
    private let snapshotMulti: Bool
    private let snapshotFailure: Bool
    private let snapshotNotch: Bool
    private var demoTask: Task<Void, Never>?
    private var recorder: DemoRecorder?
    private var preferencesTask: Task<Void, Never>?
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindowController?
    private var appearanceObserver: NSObjectProtocol?

    init(verifyOnly: Bool, snapshotPath: String?, demo: Bool = false, recordTo: String? = nil, recordNotch: Bool = false, snapshotMulti: Bool = false, snapshotFailure: Bool = false, snapshotNotch: Bool = false) {
        self.verifyOnly = verifyOnly
        self.snapshotPath = snapshotPath
        self.demo = demo
        self.recordTo = recordTo
        self.recordNotch = recordNotch
        self.snapshotMulti = snapshotMulti
        self.snapshotFailure = snapshotFailure
        self.snapshotNotch = snapshotNotch
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = NotchPanelController(
            model: model,
            onOpen: { [weak self] pipeline in self?.open(pipeline) },
            onQuit: { NSApplication.shared.terminate(nil) }
        )
        panelController = controller
        controller.screenPreference = Preferences.shared.screenPreference

        if verifyOnly {
            runVerification(controller)
            return
        }

        if let snapshotPath {
            runSnapshot(to: snapshotPath)
            return
        }

        settingsWindow = SettingsWindowController(
            model: model,
            onTokenChanged: { [weak self] in
                TokenCache.shared.invalidate()
                Haptics.resetBaseline()
                self?.refreshNow()
            }
        )
        Haptics.isEnabled = Preferences.shared.haptics
        statusItem = StatusItemController(
            model: model,
            onOpenSettings: { [weak self] in self?.settingsWindow?.show() },
            onRefresh: { [weak self] in self?.refreshNow() },
            onQuit: { NSApplication.shared.terminate(nil) }
        )

        if demo {
            // Scripted local data only — no monitor, no network, no keychain.
            print("demo mode: scripted pipelines, no GitLab calls")
            TokenCache.shared.isDisabled = true
            if let recordTo {
                demoTask = recordNotch
                    ? DemoData.runForNotchRecording(model: model)
                    : DemoData.runForRecording(model: model)
                recorder = DemoRecorder(
                    model: model,
                    outputDirectory: URL(fileURLWithPath: recordTo),
                    hasNotch: recordNotch
                )
                recorder?.start()
                return
            }
            demoTask = DemoData.run(model: model)
            observeModelForLayout()
            return
        }

        startMonitoring()
        observeModelForLayout()
        observeAppLifecycle()
        observePreferences()
    }

    /// Push the configured pipeline scope into the monitor.
    private func applyScope() {
        let monitor = self.monitor
        let scope = Preferences.shared.scope
        let groups = Preferences.shared.selectedGroups
        let username = Preferences.shared.username
        let author = Preferences.shared.authorScope
        Task.detached { await monitor.setScope(scope, groups: groups, author: author, username: username) }
    }

    /// Force an immediate poll — used after a token change or a manual refresh.
    private func refreshNow() {
        let monitor = self.monitor
        Task.detached { await monitor.refreshNow() }
    }

    /// Push preference changes into the parts of the app that read them.
    private func observePreferences() {
        var lastScreen = Preferences.shared.screenPreference
        var lastAppearance = Preferences.shared.appearance
        var lastScope = Preferences.shared.scope
        var lastGroups = Preferences.shared.selectedGroups
        var lastAuthor = Preferences.shared.authorScope
        var pushedUsername: String?

        // Push the stored scope in immediately, before the first poll lands.
        applyScope()

        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .pipelineIslandAppearanceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                lastAppearance = Preferences.shared.appearance
                self?.panelController?.applyAppearancePreference()
            }
        }

        preferencesTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }

                let screen = Preferences.shared.screenPreference
                if screen != lastScreen {
                    lastScreen = screen
                    self.panelController?.screenPreference = screen
                }

                let appearance = Preferences.shared.appearance
                if appearance != lastAppearance {
                    lastAppearance = appearance
                    self.panelController?.applyAppearancePreference()
                }

                let scope = Preferences.shared.scope
                let groups = Preferences.shared.selectedGroups
                let username = Preferences.shared.username
                let author = Preferences.shared.authorScope
                if scope != lastScope || groups != lastGroups
                    || author != lastAuthor || username != pushedUsername {
                    lastScope = scope
                    lastGroups = groups
                    lastAuthor = author
                    pushedUsername = username
                    self.applyScope()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        streamTask?.cancel()
        pumpTask?.cancel()
        visibilityTask?.cancel()
        preferencesTask?.cancel()
        demoTask?.cancel()
        statusItem?.invalidate()
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
    }

    // MARK: - Monitor wiring

    /// Subscribe first, then start.
    private func startMonitoring() {
        let monitor = self.monitor
        let model = self.model

        let consumer = Task.detached {
            let stream = await monitor.stateStream()
            let pump = Task.detached { await monitor.start() }

            for await state in stream {
                await MainActor.run { model.apply(state) }
            }
            pump.cancel()
        }
        streamTask = consumer
    }

    /// Poll the model's derived visibility and keep the panel in sync.
    private func observeModelForLayout() {
        visibilityTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.syncPanel()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func syncPanel() {
        guard let controller = panelController else { return }
        controller.refreshInteractiveRegion()
        controller.setVisible(model.isVisible)
    }

    /// Slow the poll cadence down when the machine is not being looked at.
    private func observeAppLifecycle() {
        let workspace = NSWorkspace.shared.notificationCenter

        workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main
        ) { [monitor] _ in
            Task.detached { await monitor.setSuspended(true) }
        }

        workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { [monitor] _ in
            Task.detached {
                await monitor.setSuspended(false)
                await monitor.refreshNow()
            }
        }
    }

    // MARK: - Actions

    private func open(_ pipeline: Pipeline) {
        guard let url = pipeline.webURL(host: Preferences.shared.webHost) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Render both island states offscreen to a PNG for review.
    private func runSnapshot(to path: String) {
        if snapshotMulti {
            Task { @MainActor in
                model.apply(DemoData.concurrentState(tick: 1, withFailure: snapshotFailure))
                self.writeSnapshot(to: path)
            }
            return
        }

        startMonitoring()

        Task { @MainActor in
            for _ in 0..<25 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if !model.state.pipelines.isEmpty { break }
            }
            if model.state.pipelines.isEmpty {
                model.apply(Self.sampleState())
            }
            self.writeSnapshot(to: path)
        }
    }

    /// Rasterise the collapsed + expanded pair and write it out.
    @MainActor
    private func writeSnapshot(to path: String) {
        let scheme = Preferences.shared.appearance.preferredColorScheme
        let restWidth: CGFloat = snapshotNotch ? 190 : 520
        let collapsed = Self.render(
            model: model, expanded: false, width: restWidth,
            hasNotch: snapshotNotch, colorScheme: scheme
        )
        model.isExpanded = true
        let expanded = Self.render(
            model: model, expanded: true, width: 620,
            hasNotch: snapshotNotch, colorScheme: scheme
        )

        let stacked = Self.stack([collapsed, expanded].compactMap { $0 })
        guard let image = stacked,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("snapshot: render failed")
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            let schemeLabel: String = {
                switch scheme {
                case .some(.dark): return "dark"
                case .some(.light): return "light"
                case .none: return "auto"
                @unknown default: return "auto"
                }
            }()
            print("snapshot written: \(path) (\(Int(image.size.width))x\(Int(image.size.height))) theme=\(schemeLabel)")
            print("pipelines=\(model.state.pipelines.count) live=\(model.relevantPipelines.count) mood=\(model.mood)")
            exit(0)
        } catch {
            print("snapshot: write failed \(error)")
            exit(1)
        }
    }

    /// Rasterise the island view at a fixed width.
    private static func render(
        model: IslandModel,
        expanded: Bool,
        width: CGFloat,
        hasNotch: Bool = false,
        colorScheme: ColorScheme? = Preferences.shared.appearance.preferredColorScheme
    ) -> NSImage? {
        model.isOnScreen = true

        // preferredColorScheme must wrap IslandView from outside so its body
        // sees the overridden @Environment(\.colorScheme) on first paint.
        let view = IslandView(
            model: model,
            hasNotch: hasNotch,
            notchHeight: hasNotch ? 32 : 0,
            notchWidth: hasNotch ? 190 : 0,
            onOpen: { _ in },
            onQuit: {}
        )
        .preferredColorScheme(colorScheme)

        let host = NSHostingView(rootView: AnyView(view))
        // Offscreen renders have no window appearance — pin the hosting view
        // so Light/Dark snapshots actually diverge.
        switch colorScheme {
        case .some(.light):
            host.appearance = NSAppearance(named: .aqua)
        case .some(.dark):
            host.appearance = NSAppearance(named: .darkAqua)
        case .none:
            host.appearance = NSApp.effectiveAppearance
        @unknown default:
            host.appearance = NSApp.effectiveAppearance
        }
        let height = host.fittingSize.height > 0 ? host.fittingSize.height : (expanded ? 300 : 32)
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// Stack renders vertically on a neutral ground so both states are visible.
    private static func stack(_ images: [NSImage]) -> NSImage? {
        guard !images.isEmpty else { return nil }
        let pad: CGFloat = 16
        let width = images.map(\.size.width).max() ?? 0
        let height = images.reduce(0) { $0 + $1.size.height } + pad * CGFloat(images.count + 1)
        let canvas = NSImage(size: CGSize(width: width + pad * 2, height: height))
        canvas.lockFocus()
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        CGRect(origin: .zero, size: canvas.size).fill()
        var y = height - pad
        for image in images {
            y -= image.size.height
            image.draw(at: CGPoint(x: pad, y: y), from: .zero, operation: .sourceOver, fraction: 1)
            y -= pad
        }
        canvas.unlockFocus()
        return canvas
    }

    // MARK: - Verification

    /// Prove a real window exists with non-zero bounds, then exit.
    private func runVerification(_ controller: NotchPanelController) {
        model.apply(Self.sampleState())
        controller.reposition()
        controller.setVisible(true)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)

            let frame = controller.frame
            let placement = controller.placement

            print("── panel verification ──")
            print("screen:        \(placement?.screenName ?? "?")  \(Int(placement?.screenFrame.width ?? 0))x\(Int(placement?.screenFrame.height ?? 0))")
            print("hasNotch:      \(placement?.hasNotch ?? false)  notchWidth: \(Int(placement?.notchWidth ?? 0))")
            print("panel frame:   x=\(Int(frame.origin.x)) y=\(Int(frame.origin.y)) w=\(Int(frame.width)) h=\(Int(frame.height))")
            print("panel visible: \(controller.isVisible)")

            let onScreen = frame.width > 0 && frame.height > 0 && controller.isVisible
            print(onScreen ? "RESULT: PASS — window on screen with non-zero bounds"
                           : "RESULT: FAIL — no window with non-zero bounds")
            exit(onScreen ? 0 : 1)
        }
    }

    /// Synthetic state, so the panel renders without a live pipeline.
    private static func sampleState() -> MonitorState {
        let pipeline = Pipeline(
            iid: "433",
            path: "/acme/web-app/-/pipelines/2783269154",
            status: .running,
            ref: "staging",
            source: "push",
            duration: nil,
            startedAt: Date().addingTimeInterval(-84),
            finishedAt: nil,
            detailedStatus: .init(text: "running"),
            stages: Connection(nodes: [
                Stage(name: "test", status: .success),
                Stage(name: "deploy", status: .running),
            ]),
            jobs: Connection(nodes: [
                Job(name: "test:api", status: .success, stage: .init(name: "test")),
                Job(name: "deploy:staging", status: .running, stage: .init(name: "deploy")),
            ]),
            projectPath: "acme/web-app"
        )
        return MonitorState(
            projects: [Project(fullPath: "acme/web-app", pipelines: Connection(nodes: [pipeline]))],
            lastUpdate: Date(),
            error: nil,
            isPolling: true
        )
    }
}

// MARK: - CLI harness

/// The pre-UI command surface, kept so a token can be provisioned headlessly.
enum CommandLineHarness {
    static func run(command: String, arguments: [String]) {
        switch command {
        case "store":
            guard arguments.count > 2 else {
                print("usage: PipelineIsland store <PAT>")
                exit(1)
            }
            do {
                // The token is never printed, logged, or written to disk.
                try Keychain.store(arguments[2])
                print("token stored in Keychain (service \(Keychain.service), account \(Keychain.account))")
            } catch {
                print("keychain write failed: \(error.localizedDescription)")
                exit(1)
            }

        case "migrate":
            if Keychain.migrateLegacyItem() {
                print("token migrated to the data-protection keychain")
            } else if TokenCache.shared.token() != nil {
                print("token already in the data-protection keychain — nothing to do")
            } else {
                print("no legacy token found. Run: PipelineIsland store <PAT>")
                exit(1)
            }

        case "delete":
            do {
                try Keychain.delete()
                print("token deleted")
            } catch {
                print("keychain delete failed: \(error.localizedDescription)")
                exit(1)
            }

        case "verify":
            Task {
                let code = await verifyToken()
                exit(code)
            }
            RunLoop.main.run()

        default:
            exit(1)
        }
    }

    @MainActor
    private static func verifyToken() async -> Int32 {
        guard TokenCache.shared.token() != nil else {
            print("No token in Keychain. Run: PipelineIsland store <PAT>")
            return 1
        }
        let client = GitLabClient(endpoint: GitLabClient.endpoint(for: Preferences.shared.host))
        do {
            let username = try await client.verifyToken()
            print("token OK — authenticated as \(username)")

            let projects = try await client.fetchPipelines()
            let pipelines = projects.flatMap(\.pipelineList)
            let active = pipelines.filter(\.isActive).count
            print("\(projects.count) projects, \(pipelines.count) pipelines, \(active) active")
            return 0
        } catch {
            let message = (error as? GitLabError)?.errorDescription ?? error.localizedDescription
            print("FAILED: \(message)")
            return 1
        }
    }
}
