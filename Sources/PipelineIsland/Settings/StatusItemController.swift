import AppKit
import SwiftUI

/// The menu bar status item — the app's permanent handle.
@MainActor
public final class StatusItemController {
    private let statusItem: NSStatusItem
    private let model: IslandModel
    private let onOpenSettings: () -> Void
    private let onRefresh: () -> Void
    private let onQuit: () -> Void

    private var pollTask: Task<Void, Never>?
    private var lastMood: IslandMood?
    private var lastCount: Int = -1
    private var lastUpdate: String?

    public init(
        model: IslandModel,
        onOpenSettings: @escaping () -> Void,
        onRefresh: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.model = model
        self.onOpenSettings = onOpenSettings
        self.onRefresh = onRefresh
        self.onQuit = onQuit

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()
        rebuildMenu()
        startObserving()
        UpdateCheck.checkIfDue()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = Self.symbol(for: .idle)
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        button.toolTip = "Pipeline Island"
    }

    /// Build the icon for a mood.
    private static func symbol(for mood: IslandMood, hasToken: Bool = true) -> NSImage? {
        guard hasToken else {
            return tinted("exclamationmark.circle", .systemOrange, template: false)
        }
        switch mood {
        case .idle:
            let image = NSImage(
                systemSymbolName: "smallcircle.filled.circle",
                accessibilityDescription: "Pipeline Island — idle"
            )
            image?.isTemplate = true
            return image
        case .running:
            return tinted("circle.dotted", .systemBlue, template: false)
        case .failed:
            return tinted("xmark.circle.fill", .systemRed, template: false)
        case .success:
            return tinted("checkmark.circle.fill", .systemGreen, template: false)
        case .error:
            return tinted("exclamationmark.circle", .systemOrange, template: false)
        }
    }

    private static func tinted(_ name: String, _ colour: NSColor, template: Bool) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: name) else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(paletteColors: [colour])
        let image = base.withSymbolConfiguration(config) ?? base
        image.isTemplate = template
        return image
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Live summary line, disabled — a label rather than an action.
        let summary = NSMenuItem(title: summaryTitle(), action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)

        // One entry per live pipeline, click to open in the browser.
        let live = model.relevantPipelines
        if !live.isEmpty {
            menu.addItem(.separator())
            for pipeline in live.prefix(8) {
                let title = "\(pipeline.projectPath) #\(pipeline.iid) · \(pipeline.ref ?? "—")"
                let item = NSMenuItem(
                    title: title,
                    action: #selector(openPipeline(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = pipeline
                item.image = Self.symbol(for: IslandModel.mood(for: pipeline.status))
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        if let version = UpdateCheck.availableVersion {
            let update = NSMenuItem(
                title: "Update available: \(version)",
                action: #selector(openUpdate),
                keyEquivalent: ""
            )
            update.target = self
            update.image = NSImage(systemSymbolName: "arrow.down.circle.fill",
                                   accessibilityDescription: "Update available")
            menu.addItem(update)
            menu.addItem(.separator())
        }

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let theme = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu()
        for preference in AppearancePreference.allCases {
            let item = NSMenuItem(
                title: preference.title,
                action: #selector(setTheme(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = preference.rawValue
            item.state = Preferences.shared.appearance == preference ? .on : .off
            themeMenu.addItem(item)
        }
        theme.submenu = themeMenu
        menu.addItem(theme)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Pipeline Island", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func summaryTitle() -> String {
        if let error = model.state.error {
            return error
        }
        let live = model.relevantPipelines
        guard !live.isEmpty else { return "No pipelines running" }
        let running = live.filter(\.isActive).count
        let failed = live.filter { $0.status == .failed }.count
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.isEmpty ? "\(live.count) recent" : parts.joined(separator: ", ")
    }

    // MARK: - Actions

    @objc private func openPipeline(_ sender: NSMenuItem) {
        guard let pipeline = sender.representedObject as? Pipeline,
              let url = pipeline.webURL(host: Preferences.shared.webHost) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func refresh() { onRefresh() }

    @objc private func openUpdate() { UpdateCheck.openReleasePage() }
    @objc private func openSettings() { onOpenSettings() }
    @objc private func quit() { onQuit() }

    @objc private func setTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preference = AppearancePreference(rawValue: raw) else { return }
        Preferences.shared.appearance = preference
        NotificationCenter.default.post(name: .pipelineIslandAppearanceDidChange, object: nil)
        rebuildMenu()
    }

    // MARK: - State

    /// Keep the icon and menu in step with the model.
    private func startObserving() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.sync()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func sync() {
        let mood = model.mood
        let count = model.relevantPipelines.count
        let update = UpdateCheck.availableVersion
        guard mood != lastMood || count != lastCount || update != lastUpdate else { return }
        lastUpdate = update
        lastMood = mood
        lastCount = count

        if let button = statusItem.button {
            button.image = Self.symbol(for: mood, hasToken: TokenCache.shared.token() != nil)
            button.title = count > 1 ? " \(count)" : ""
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        }
        rebuildMenu()
    }

    public func invalidate() {
        pollTask?.cancel()
        pollTask = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}
