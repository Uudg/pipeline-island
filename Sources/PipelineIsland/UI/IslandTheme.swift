import SwiftUI

/// Manual override for the island chrome. `auto` follows the OS.
public enum AppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case auto
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "Auto"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// SwiftUI override applied on island content only.
    /// `nil` means follow the system — never assign to `NSApp.appearance`.
    public var preferredColorScheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Appearance-aware island colours.
///
/// Always resolve via `resolved(colorScheme:hasNotch:)` inside a View body so
/// colours are taken from the *current drawing* appearance — never from a
/// palette captured at launch. Caching a launch-time palette is the usual
/// cause of "looked right at start, wrong after switching to Light".
struct IslandPalette: Equatable {
    let background: Color
    let backgroundSolid: Color
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color
    let border: Color
    let hoverFill: Color
    let divider: Color
    let success: Color
    let failure: Color
    let running: Color
    let warning: Color
    let idle: Color
    let connector: Color
    let shadow: Color
    let isDark: Bool

    /// Dark chrome — matches the notch bezel and the original island look.
    /// Status greens stay bright on black (#68CE67 ≈ 8:1).
    static let dark = IslandPalette(
        background: Color.black.opacity(0.92),
        backgroundSolid: .black,
        primaryText: .white,
        secondaryText: Color.white.opacity(0.75),
        tertiaryText: Color.white.opacity(0.45),
        border: Color.white.opacity(0.08),
        hoverFill: Color.white.opacity(0.07),
        divider: Color.white.opacity(0.14),
        success: Color(hex: 0x68CE67),
        failure: Color(hex: 0xFF5F57),
        running: Color(hex: 0x5B9CFF),
        warning: Color(hex: 0xFFB020),
        idle: Color.white.opacity(0.25),
        connector: Color.white.opacity(0.18),
        shadow: Color.black.opacity(0.35),
        isDark: true
    )

    /// Light chrome for notchless displays. Status colours are darkened so
    /// they clear ≥3:1 against white (#68CE67 is only ~1.7:1 on white).
    static let light = IslandPalette(
        background: Color(hex: 0xF4F5F7).opacity(0.97),
        backgroundSolid: Color(hex: 0xF4F5F7),
        primaryText: Color(hex: 0x1A1A1A),
        secondaryText: Color(hex: 0x1A1A1A).opacity(0.72),
        tertiaryText: Color(hex: 0x1A1A1A).opacity(0.48),
        border: Color.black.opacity(0.10),
        hoverFill: Color.black.opacity(0.06),
        divider: Color.black.opacity(0.10),
        success: Color(hex: 0x1B8A3C),
        failure: Color(hex: 0xC62828),
        running: Color(hex: 0x0B6BCB),
        warning: Color(hex: 0xB86E00),
        idle: Color.black.opacity(0.28),
        connector: Color.black.opacity(0.18),
        shadow: Color.black.opacity(0.18),
        isDark: false
    )

    /// Paint-time resolution. A physical notch is black hardware, so the
    /// island chrome under it stays dark regardless of the OS scheme.
    static func resolved(colorScheme: ColorScheme, hasNotch: Bool) -> IslandPalette {
        if hasNotch { return .dark }
        return colorScheme == .dark ? .dark : .light
    }

    func color(for status: PipelineStatus) -> Color {
        if status.isActive { return running }
        switch status {
        case .success: return success
        case .failed: return failure
        case .canceled, .canceling, .skipped: return tertiaryText
        case .manual, .scheduled: return warning
        default: return tertiaryText
        }
    }

    func color(for mood: IslandMood) -> Color {
        switch mood {
        case .running: return running
        case .failed: return failure
        case .success: return success
        case .error: return warning
        case .idle: return idle
        }
    }
}

private struct IslandPaletteKey: EnvironmentKey {
    static let defaultValue = IslandPalette.dark
}

extension EnvironmentValues {
    var islandPalette: IslandPalette {
        get { self[IslandPaletteKey.self] }
        set { self[IslandPaletteKey.self] = newValue }
    }
}

extension Color {
    /// sRGB from a 0xRRGGBB literal.
    init(hex: UInt32, opacity: Double = 1) {
        let red = Double((hex >> 16) & 0xff) / 255
        let green = Double((hex >> 8) & 0xff) / 255
        let blue = Double(hex & 0xff) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}

extension Notification.Name {
    /// Posted when the user changes Theme (Auto / Light / Dark).
    static let pipelineIslandAppearanceDidChange = Notification.Name("pipelineIsland.appearanceDidChange")
}
