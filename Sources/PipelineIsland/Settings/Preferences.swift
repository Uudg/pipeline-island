import Foundation
import SwiftUI

/// User-facing settings, persisted in `UserDefaults`.
@MainActor
@Observable
public final class Preferences {
    public static let shared = Preferences()

    private enum Key {
        static let host = "gitlab.host"
        static let screenPreference = "island.screen"
        static let scope = "pipelines.scope"
        static let selectedGroups = "pipelines.groups"
        static let username = "account.username"
        static let authorScope = "pipelines.author"
        static let haptics = "island.haptics"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.host = defaults.string(forKey: Key.host) ?? "https://gitlab.com"
        self.screenPreference = NotchGeometry.ScreenPreference(
            rawValue: defaults.string(forKey: Key.screenPreference) ?? ""
        ) ?? .primary
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

    /// Which display the island renders on.
    public var screenPreference: NotchGeometry.ScreenPreference {
        didSet { defaults.set(screenPreference.rawValue, forKey: Key.screenPreference) }
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
