import AppKit
import SwiftUI

/// Settings window.
@MainActor
public final class SettingsWindowController {
    private var window: NSWindow?
    private let model: IslandModel
    private let onTokenChanged: () -> Void

    public init(model: IslandModel, onTokenChanged: @escaping () -> Void) {
        self.model = model
        self.onTokenChanged = onTokenChanged
    }

    public func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = SettingsView(
            model: model,
            onTokenChanged: onTokenChanged,
            onClose: { [weak self] in self?.close() }
        )

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Pipeline Island Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 480, height: 520))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    public func close() {
        window?.close()
    }
}

/// The settings pane itself.
struct SettingsView: View {
    @Bindable var model: IslandModel
    let onTokenChanged: () -> Void
    let onClose: () -> Void

    @State private var preferences = Preferences.shared
    @State private var tokenField = ""
    @State private var tokenStatus: TokenStatus = .unknown
    @State private var isVerifying = false
    @State private var groups: [GitLabGroup] = []
    @State private var isLoadingGroups = false
    @State private var username: String?
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    enum TokenStatus: Equatable {
        case unknown
        case stored(username: String)
        case missing
        case invalid(String)

        var colour: Color {
            switch self {
            case .stored: return .green
            case .invalid: return .red
            case .missing: return .orange
            case .unknown: return .secondary
            }
        }

        var label: String {
            switch self {
            case .unknown: return "Not checked"
            case .stored(let username): return "Connected as \(username)"
            case .missing: return "No token stored"
            case .invalid(let message): return message
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    account
                    Divider()
                    pipelineScope
                    Divider()
                    display
                }
                .padding(20)
            }

            Divider()

            HStack {
                Text("Pipeline Island \(Bundle.main.shortVersion)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 480, minHeight: 560)
        .onAppear {
            checkToken()
            loadGroups()
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }

    // MARK: - Pipeline scope

    private var pipelineScope: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which pipelines")
                .font(.headline)

            ForEach(PipelineScope.allCases, id: \.self) { option in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: preferences.scope == option
                              ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(preferences.scope == option ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.label)
                                .font(.system(size: 12, weight: .medium))
                            Text(option.detail)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if let count = projectCount(for: option) {
                            Text("\(count)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { preferences.scope = option }
                }
            }

            // Group picker, only meaningful for the .groups scope.
            if preferences.scope == .groups {
                VStack(alignment: .leading, spacing: 6) {
                    if isLoadingGroups {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Loading your groups…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if groups.isEmpty {
                        Text("No groups found for this account.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(groups) { group in
                            Toggle(isOn: Binding(
                                get: { preferences.selectedGroups.contains(group.fullPath) },
                                set: { on in
                                    if on { preferences.selectedGroups.insert(group.fullPath) }
                                    else { preferences.selectedGroups.remove(group.fullPath) }
                                }
                            )) {
                                HStack(spacing: 6) {
                                    Text(group.fullPath)
                                        .font(.system(size: 11, design: .monospaced))
                                    if let count = group.projectsCount {
                                        Text("\(count) project\(count == 1 ? "" : "s")")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .padding(.leading, 24)
                .padding(.top, 2)
            }

            // Author scope — a separate axis from project scope.
            Divider().padding(.vertical, 4)

            Text("Whose runs")
                .font(.system(size: 12, weight: .semibold))

            ForEach(PipelineAuthorScope.allCases, id: \.self) { option in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: preferences.authorScope == option
                          ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(preferences.authorScope == option
                                         ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.label)
                            .font(.system(size: 12, weight: .medium))
                        Text(option.detail)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if let count = pipelineCount(for: option) {
                        Text("\(count)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { preferences.authorScope = option }
            }
        }
    }

    /// Live count of pipelines each author scope would show.
    private func pipelineCount(for option: PipelineAuthorScope) -> Int? {
        let pipelines = model.state.pipelines
        guard !pipelines.isEmpty else { return nil }
        switch option {
        case .everyone:
            return pipelines.count
        case .me:
            guard let username else { return nil }
            return pipelines.filter { $0.wasTriggered(by: username) }.count
        }
    }

    /// How many watched projects each scope would yield, from live data.
    private func projectCount(for scope: PipelineScope) -> Int? {
        let projects = model.state.projects
        guard !projects.isEmpty else { return nil }
        switch scope {
        case .all:
            return projects.count
        case .mine:
            guard let username else { return nil }
            return projects.filter { $0.isPersonal(of: username) }.count
        case .groups:
            return projects.filter { project in
                guard let group = project.groupPath else { return false }
                return preferences.selectedGroups.contains {
                    group == $0 || group.hasPrefix($0 + "/")
                }
            }.count
        }
    }

    // MARK: - Display

    private var display: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where to show the island")
                .font(.headline)

            ForEach(displayOptions, id: \.preference) { option in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: preferences.screenPreference == option.preference
                          ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(preferences.screenPreference == option.preference
                                         ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.title)
                            .font(.system(size: 12, weight: .medium))
                        Text(option.detail)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { preferences.screenPreference = option.preference }
            }

            Divider().padding(.vertical, 4)

            Text("Theme")
                .font(.system(size: 12, weight: .medium))
            Picker("Theme", selection: Binding(
                get: { preferences.appearance },
                set: { next in
                    preferences.appearance = next
                    NotificationCenter.default.post(
                        name: .pipelineIslandAppearanceDidChange,
                        object: nil
                    )
                }
            )) {
                ForEach(AppearancePreference.allCases) { preference in
                    Text(preference.title).tag(preference)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Auto follows macOS. Light uses darkened status colours (≥3:1 on white).")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Toggle(isOn: Binding(
                get: { launchAtLogin },
                set: { wanted in
                    switch LaunchAtLogin.set(wanted) {
                    case .success(let actual):
                        launchAtLogin = actual
                        launchError = nil
                    case .failure(let error):
                        launchAtLogin = LaunchAtLogin.isEnabled
                        launchError = error.localizedDescription
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Launch at login")
                        .font(.system(size: 12, weight: .medium))
                    Text(launchError ?? LaunchAtLogin.statusDescription)
                        .font(.caption)
                        .foregroundStyle(launchError == nil ? Color.secondary.opacity(0.7) : Color.red)
                }
            }
            .toggleStyle(.switch)

            if LaunchAtLogin.wasDeniedBySystem {
                Button("Open Login Items…") { LaunchAtLogin.openSystemSettings() }
                    .controlSize(.small)
                    .padding(.leading, 2)
            }

            Toggle(isOn: $preferences.haptics) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Haptic feedback")
                        .font(.system(size: 12, weight: .medium))
                    Text(hapticsDetail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)

            if preferences.haptics {
                HStack(spacing: 8) {
                    Text("Try:")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button("Start") { Haptics.demoStart() }
                    Button("Success") { Haptics.demoSuccess() }
                    Button("Failure") { Haptics.demoFailure() }
                }
                .controlSize(.small)
                .padding(.leading, 2)
            }
        }
    }

    /// Say plainly whether haptics can actually be felt on this hardware.
    private var hapticsDetail: String {
        Haptics.isSupported
            ? "A tap when a pipeline starts, finishes, or fails. Requires a Force Touch trackpad."
            : "No Force Touch trackpad detected — haptics will not be felt on a mouse."
    }

    private struct DisplayOption {
        let preference: NotchGeometry.ScreenPreference
        let title: String
        let detail: String
    }

    /// Display choices, labelled with the actual attached screens.
    private var displayOptions: [DisplayOption] {
        let screens = NSScreen.screens
        func describe(_ screen: NSScreen?) -> String {
            guard let screen else { return "not attached" }
            let size = "\(Int(screen.frame.width))×\(Int(screen.frame.height))"
            let notch = screen.safeAreaInsets.top > 0 ? ", has a notch" : ""
            return "\(screen.localizedName) — \(size)\(notch)"
        }

        let notched = screens.first { $0.safeAreaInsets.top > 0 }
        let builtIn = screens.first {
            $0.safeAreaInsets.top > 0
                || $0.localizedName.lowercased().contains("built-in")
                || $0.localizedName.lowercased().contains("liquid retina")
        }
        let external = screens.first { screen in
            !(screen.safeAreaInsets.top > 0
                || screen.localizedName.lowercased().contains("built-in")
                || screen.localizedName.lowercased().contains("liquid retina"))
        }

        return [
            DisplayOption(
                preference: .notched,
                title: "Notch display",
                detail: notched.map(describe) ?? "No notched display attached — falls back to the menu bar display."
            ),
            DisplayOption(
                preference: .primary,
                title: "Main display",
                detail: describe(screens.first { $0.frame.origin == .zero } ?? screens.first)
            ),
            DisplayOption(
                preference: .main,
                title: "Active display",
                detail: "Wherever the keyboard focus is — the island follows you between screens."
            ),
            DisplayOption(
                preference: .builtIn,
                title: "Built-in display",
                detail: builtIn.map(describe) ?? "Lid closed or no built-in display detected."
            ),
            DisplayOption(
                preference: .external,
                title: "External display",
                detail: external.map(describe) ?? "No external display attached — falls back to the menu bar display."
            ),
        ]
    }

    // MARK: - Account

    private var account: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("GitLab Account")
                .font(.headline)

            HStack(spacing: 8) {
                Circle()
                    .fill(tokenStatus.colour)
                    .frame(width: 8, height: 8)
                Text(tokenStatus.label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                if isVerifying {
                    ProgressView().controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                Text("API Host")
                    .frame(width: 68, alignment: .leading)
                TextField("https://gitlab.com", text: $preferences.host)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 8) {
                Text("Web Host")
                    .frame(width: 68, alignment: .leading)
                TextField("Defaults to API Host", text: $preferences.webHost)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 8) {
                Text("Token")
                    .frame(width: 68, alignment: .leading)
                SecureField("glpat-…", text: $tokenField)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { saveToken() }
                    .disabled(tokenField.isEmpty)
            }

            Text("Create a token with the **read_api** scope. It is stored in your macOS Keychain, never on disk. Web Host controls browser links when the API uses a different LAN address.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Open GitLab Token Settings") {
                    let base = preferences.webHost.trimmingCharacters(in: .whitespaces)
                    if let url = URL(string: base + "/-/user_settings/personal_access_tokens") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Verify") { checkToken(force: true) }
                Button("Remove Token", role: .destructive) { removeToken() }
            }
            .controlSize(.small)
        }
    }

    // MARK: - Token actions

    private func saveToken() {
        let trimmed = tokenField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try Keychain.store(trimmed)
            tokenField = ""
            onTokenChanged()
            checkToken(force: true)
        } catch {
            tokenStatus = .invalid(error.localizedDescription)
        }
    }

    private func removeToken() {
        try? Keychain.delete()
        tokenStatus = .missing
        onTokenChanged()
    }

    /// Load the user's groups for the organization picker.
    private func loadGroups() {
        guard TokenCache.shared.token() != nil, groups.isEmpty else { return }
        isLoadingGroups = true
        Task {
            let client = GitLabClient(
                endpoint: GitLabClient.endpoint(for: Preferences.shared.host)
            )
            let result = try? await client.fetchGroups()
            await MainActor.run {
                if let result {
                    username = result.username
                    Preferences.shared.username = result.username
                    groups = result.groups.sorted { $0.fullPath < $1.fullPath }
                }
                isLoadingGroups = false
            }
        }
    }

    private func checkToken(force: Bool = false) {
        guard TokenCache.shared.token() != nil else {
            tokenStatus = .missing
            return
        }
        guard force || tokenStatus == .unknown else { return }
        isVerifying = true
        Task {
            let client = GitLabClient(
                endpoint: GitLabClient.endpoint(for: Preferences.shared.host)
            )
            do {
                let username = try await client.verifyToken()
                await MainActor.run {
                    tokenStatus = .stored(username: username)
                    Preferences.shared.username = username
                    isVerifying = false
                }
            } catch {
                await MainActor.run {
                    let message = (error as? GitLabError)?.errorDescription
                        ?? error.localizedDescription
                    tokenStatus = .invalid(message)
                    isVerifying = false
                }
            }
        }
    }
}

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
