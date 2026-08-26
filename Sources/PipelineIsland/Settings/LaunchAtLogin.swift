import AppKit
import ServiceManagement

/// Launch at login, via `SMAppService`.
///
/// The modern replacement for `SMLoginItemSetEnabled` and the old
/// `LSSharedFileList` API. Registering adds the app to System Settings →
/// General → Login Items, where the user can turn it off independently — so
/// the stored preference can drift from reality and the system is always the
/// source of truth.
@MainActor
enum LaunchAtLogin {
    /// Whether macOS will start the app at login.
    ///
    /// Read from `SMAppService`, never from a stored preference: the user can
    /// disable it in System Settings without the app being told.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when the user disabled it in System Settings after the app asked
    /// for it. Worth surfacing, since re-registering silently would fight them.
    static var wasDeniedBySystem: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Turn it on or off. Returns the resulting state.
    @discardableResult
    static func set(_ enabled: Bool) -> Result<Bool, Error> {
        do {
            if enabled {
                // register() throws if already registered, which is not an
                // error worth surfacing.
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            return .success(isEnabled)
        } catch {
            return .failure(error)
        }
    }

    /// Open the Login Items pane, for when the system has overridden us.
    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Diagnostic for `--login-status`.
    static func printStatus() {
        let status = SMAppService.mainApp.status
        let names = [0: "notRegistered", 1: "enabled", 2: "requiresApproval", 3: "notFound"]
        print("SMAppService.mainApp.status = \(status.rawValue) (\(names[status.rawValue] ?? "?"))")
        print("bundle: \(Bundle.main.bundlePath)")
        print("isEnabled: \(isEnabled)")
        print(statusDescription)
    }

    /// Human-readable state, for Settings.
    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "Pipeline Island will start when you log in."
        case .requiresApproval:
            return "Turned off in System Settings → General → Login Items."
        case .notFound:
            // Measured: this is what an app that has simply never registered
            // reports, even from /Applications. register() succeeds from here.
            return "Pipeline Island will not start automatically."
        case .notRegistered:
            return "Pipeline Island will not start automatically."
        @unknown default:
            return ""
        }
    }
}
