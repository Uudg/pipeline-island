import AppKit
import Foundation
import SwiftUI

/// User-facing settings, persisted in `UserDefaults`.
@MainActor
@Observable
public final class Preferences {
    public static let shared = Preferences()

    private enum Key {
        static let host = "gitlab.host"
        static let webHost = "gitlab.webHost"
        static let screenPreference = "island.screen"
        static let appearance = "island.appearance"
        static let scope = "pipelines.scope"
        static let selectedGroups = "pipelines.groups"
        static let username = "account.username"
        static let authorScope = "pipelines.author"
        static let haptics = "island.haptics"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let host = defaults.string(forKey: Key.host) ?? "https://gitlab.com"
        self.host = host
        self.webHost = defaults.string(forKey: Key.webHost) ?? host
        self.screenPreference = NotchGeometry.ScreenPreference(
            rawValue: defaults.string(forKey: Key.screenPreference) ?? ""
        ) ?? .primary
        // Env wins for snapshot/CI: PIPELINE_ISLAND_THEME=light|dark|auto
        if let env = ProcessInfo.processInfo.environment["PIPELINE_ISLAND_THEME"],
           let forced = AppearancePreference(rawValue: env) {
            self.appearance = forced
        } else {
            self.appearance = AppearancePreference(
                rawValue: defaults.string(forKey: Key.appearance) ?? ""
            ) ?? .auto
        }
        self.scope = PipelineScope(rawValue: defaults.string(forKey: Key.scope) ?? "") ?? .all
        self.selectedGroups = Set(defaults.stringArray(forKey: Key.selectedGroups) ?? [])
        self.username = defaults.string(forKey: Key.username)
        self.authorScope = PipelineAuthorScope(rawValue: defaults.string(forKey: Key.authorScope) ?? "") ?? .everyone
        self.haptics = defaults.object(forKey: Key.haptics) as? Bool ?? true
    }

    /// GitLab instance. Self-hosted installs point this elsewhere.
    public var host: String {
        didSet { defaults.set(host, forKey: Key.host) }
    }

    /// Browser-facing GitLab origin. May differ from the API host on split-DNS setups.
    public var webHost: String {
        didSet { defaults.set(webHost, forKey: Key.webHost) }
    }

    /// Which display the island renders on.
    public var screenPreference: NotchGeometry.ScreenPreference {
        didSet { defaults.set(screenPreference.rawValue, forKey: Key.screenPreference) }
    }

    /// Island chrome: follow the OS, or force Light / Dark.
    ///
    /// Never assigned to `NSApp.appearance` — overrides apply only via
    /// `preferredColorScheme` on the island content.
    public var appearance: AppearancePreference {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    /// Which projects the island reports on.
    public var scope: PipelineScope {
        didSet { defaults.set(scope.rawValue, forKey: Key.scope) }
    }

    /// Group paths selected when `scope == .groups`.
    public var selectedGroups: Set<String> {
        didSet { defaults.set(Array(selectedGroups).sorted(), forKey: Key.selectedGroups) }
    }

    /// The signed-in user's namespace, learned from the API.
    public var username: String? {
        didSet { defaults.set(username, forKey: Key.username) }
    }

    /// Haptic feedback on pipeline transitions.
    public var haptics: Bool {
        didSet {
            defaults.set(haptics, forKey: Key.haptics)
            Haptics.isEnabled = haptics
        }
    }

    /// Whose runs to show. Separate axis from `scope`.
    public var authorScope: PipelineAuthorScope {
        didSet { defaults.set(authorScope.rawValue, forKey: Key.authorScope) }
    }
}
