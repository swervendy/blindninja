import AppKit
import SwiftTerm

struct TerminalColors {
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor
    let ansi: [NSColor] // 16 colors: 8 normal + 8 bright
}

struct AppTheme {
    let id: String
    let name: String

    // App chrome
    let sidebarBackground: NSColor
    let sidebarText: NSColor
    let sidebarTextSecondary: NSColor
    let headerBackground: NSColor
    let borderColor: NSColor
    let selectedBackground: NSColor
    let hoverBackground: NSColor

    // State dots
    let waitingColor: NSColor   // green
    let workingColor: NSColor   // amber
    let blockedColor: NSColor   // red
    let idleColor: NSColor      // gray

    // Terminal
    let terminal: TerminalColors
}

// MARK: - Theme Definitions

extension AppTheme {
    static let blueTitanium = AppTheme(
        id: "blue-titanium", name: "Blue Titanium",
        sidebarBackground: NSColor(hex: "#141620"),
        sidebarText: NSColor(hex: "#b8bcc8"),
        sidebarTextSecondary: NSColor(hex: "#6a6e80"),
        headerBackground: NSColor(hex: "#1a1e2e"),
        borderColor: NSColor(hex: "#252838"),
        selectedBackground: NSColor(hex: "#1e2235"),
        hoverBackground: NSColor(hex: "#1a1e30"),
        waitingColor: NSColor(hex: "#7ee0a5"),
        workingColor: NSColor(hex: "#e8c468"),
        blockedColor: NSColor(hex: "#e07878"),
        idleColor: NSColor(hex: "#555555"),
        terminal: TerminalColors(
            background: NSColor(hex: "#1a1e2e"),
            foreground: NSColor(hex: "#b8bcc8"),
            cursor: NSColor(hex: "#b8bcc8"),
            ansi: [
                NSColor(hex: "#151828"), NSColor(hex: "#c07070"),
                NSColor(hex: "#6aba88"), NSColor(hex: "#c8b870"),
                NSColor(hex: "#6aa0c8"), NSColor(hex: "#a080b8"),
                NSColor(hex: "#70aac0"), NSColor(hex: "#b8bcc8"),
                NSColor(hex: "#4a5068"), NSColor(hex: "#d88888"),
                NSColor(hex: "#80c898"), NSColor(hex: "#d8c880"),
                NSColor(hex: "#80b8d8"), NSColor(hex: "#b898c8"),
                NSColor(hex: "#88bcd0"), NSColor(hex: "#d0d4e0"),
            ]
        )
    )

    static let midnight = AppTheme(
        id: "midnight", name: "Midnight",
        sidebarBackground: NSColor(hex: "#0a0a0a"),
        sidebarText: NSColor(hex: "#c8c8c8"),
        sidebarTextSecondary: NSColor(hex: "#666666"),
        headerBackground: NSColor(hex: "#0d0d0d"),
        borderColor: NSColor(hex: "#1a1a1a"),
        selectedBackground: NSColor(hex: "#1a1a1a"),
        hoverBackground: NSColor(hex: "#151515"),
        waitingColor: NSColor(hex: "#7ee0a5"),
        workingColor: NSColor(hex: "#e8c468"),
        blockedColor: NSColor(hex: "#e07878"),
        idleColor: NSColor(hex: "#555555"),
        terminal: TerminalColors(
            background: NSColor(hex: "#0d0d0d"),
            foreground: NSColor(hex: "#c8c8c8"),
            cursor: NSColor(hex: "#c8c8c8"),
            ansi: [
                NSColor(hex: "#0a0a0a"), NSColor(hex: "#c07070"),
                NSColor(hex: "#5cb87a"), NSColor(hex: "#d4a844"),
                NSColor(hex: "#7aa2c0"), NSColor(hex: "#a080b8"),
                NSColor(hex: "#70aac0"), NSColor(hex: "#c8c8c8"),
                NSColor(hex: "#555555"), NSColor(hex: "#d88888"),
                NSColor(hex: "#78d090"), NSColor(hex: "#e0b850"),
                NSColor(hex: "#90b8d8"), NSColor(hex: "#b898c8"),
                NSColor(hex: "#88bcd0"), NSColor(hex: "#e0e0e0"),
            ]
        )
    )

    static let solarizedDark = AppTheme(
        id: "solarized-dark", name: "Solarized Dark",
        sidebarBackground: NSColor(hex: "#001e26"),
        sidebarText: NSColor(hex: "#839496"),
        sidebarTextSecondary: NSColor(hex: "#586e75"),
        headerBackground: NSColor(hex: "#002b36"),
        borderColor: NSColor(hex: "#073642"),
        selectedBackground: NSColor(hex: "#073642"),
        hoverBackground: NSColor(hex: "#053340"),
        waitingColor: NSColor(hex: "#859900"),
        workingColor: NSColor(hex: "#b58900"),
        blockedColor: NSColor(hex: "#dc322f"),
        idleColor: NSColor(hex: "#586e75"),
        terminal: TerminalColors(
            background: NSColor(hex: "#002b36"),
            foreground: NSColor(hex: "#839496"),
            cursor: NSColor(hex: "#839496"),
            ansi: [
                NSColor(hex: "#073642"), NSColor(hex: "#dc322f"),
                NSColor(hex: "#859900"), NSColor(hex: "#b58900"),
                NSColor(hex: "#268bd2"), NSColor(hex: "#d33682"),
                NSColor(hex: "#2aa198"), NSColor(hex: "#eee8d5"),
                NSColor(hex: "#586e75"), NSColor(hex: "#cb4b16"),
                NSColor(hex: "#859900"), NSColor(hex: "#b58900"),
                NSColor(hex: "#268bd2"), NSColor(hex: "#6c71c4"),
                NSColor(hex: "#2aa198"), NSColor(hex: "#fdf6e3"),
            ]
        )
    )

    static let rosePine = AppTheme(
        id: "rose-pine", name: "Rose Pine",
        sidebarBackground: NSColor(hex: "#13111e"),
        sidebarText: NSColor(hex: "#e0def4"),
        sidebarTextSecondary: NSColor(hex: "#555170"),
        headerBackground: NSColor(hex: "#191724"),
        borderColor: NSColor(hex: "#26233a"),
        selectedBackground: NSColor(hex: "#26233a"),
        hoverBackground: NSColor(hex: "#1f1d2e"),
        waitingColor: NSColor(hex: "#31748f"),
        workingColor: NSColor(hex: "#f6c177"),
        blockedColor: NSColor(hex: "#eb6f92"),
        idleColor: NSColor(hex: "#555170"),
        terminal: TerminalColors(
            background: NSColor(hex: "#191724"),
            foreground: NSColor(hex: "#e0def4"),
            cursor: NSColor(hex: "#e0def4"),
            ansi: [
                NSColor(hex: "#26233a"), NSColor(hex: "#eb6f92"),
                NSColor(hex: "#31748f"), NSColor(hex: "#f6c177"),
                NSColor(hex: "#9ccfd8"), NSColor(hex: "#c4a7e7"),
                NSColor(hex: "#ebbcba"), NSColor(hex: "#e0def4"),
                NSColor(hex: "#555170"), NSColor(hex: "#eb6f92"),
                NSColor(hex: "#31748f"), NSColor(hex: "#f6c177"),
                NSColor(hex: "#9ccfd8"), NSColor(hex: "#c4a7e7"),
                NSColor(hex: "#ebbcba"), NSColor(hex: "#e0def4"),
            ]
        )
    )

    static let light = AppTheme(
        id: "light", name: "Light",
        sidebarBackground: NSColor(hex: "#f5f5f7"),
        sidebarText: NSColor(hex: "#1d1d1f"),
        sidebarTextSecondary: NSColor(hex: "#6e6e73"),
        headerBackground: NSColor(hex: "#ffffff"),
        borderColor: NSColor(hex: "#d2d2d7"),
        selectedBackground: NSColor(hex: "#e8e8ed"),
        hoverBackground: NSColor(hex: "#ececf0"),
        waitingColor: NSColor(hex: "#248a3d"),
        workingColor: NSColor(hex: "#a05e00"),
        blockedColor: NSColor(hex: "#d70015"),
        idleColor: NSColor(hex: "#aeaeb2"),
        terminal: TerminalColors(
            background: NSColor(hex: "#ffffff"),
            foreground: NSColor(hex: "#1d1d1f"),
            cursor: NSColor(hex: "#1d1d1f"),
            ansi: [
                NSColor(hex: "#000000"), NSColor(hex: "#c41a15"),
                NSColor(hex: "#007400"), NSColor(hex: "#826b00"),
                NSColor(hex: "#0000e0"), NSColor(hex: "#a9009a"),
                NSColor(hex: "#007676"), NSColor(hex: "#d0d0d0"),
                NSColor(hex: "#6e6e73"), NSColor(hex: "#d70015"),
                NSColor(hex: "#248a3d"), NSColor(hex: "#a05e00"),
                NSColor(hex: "#0071e3"), NSColor(hex: "#b040a0"),
                NSColor(hex: "#008888"), NSColor(hex: "#f5f5f7"),
            ]
        )
    )

    static let solarizedLight = AppTheme(
        id: "solarized-light", name: "Solarized Light",
        sidebarBackground: NSColor(hex: "#f0eadb"),
        sidebarText: NSColor(hex: "#586e75"),
        sidebarTextSecondary: NSColor(hex: "#93a1a1"),
        headerBackground: NSColor(hex: "#fdf6e3"),
        borderColor: NSColor(hex: "#ddd5c1"),
        selectedBackground: NSColor(hex: "#eee8d5"),
        hoverBackground: NSColor(hex: "#f0eadb"),
        waitingColor: NSColor(hex: "#859900"),
        workingColor: NSColor(hex: "#b58900"),
        blockedColor: NSColor(hex: "#dc322f"),
        idleColor: NSColor(hex: "#93a1a1"),
        terminal: TerminalColors(
            background: NSColor(hex: "#fdf6e3"),
            foreground: NSColor(hex: "#586e75"),
            cursor: NSColor(hex: "#586e75"),
            ansi: [
                NSColor(hex: "#073642"), NSColor(hex: "#dc322f"),
                NSColor(hex: "#859900"), NSColor(hex: "#b58900"),
                NSColor(hex: "#268bd2"), NSColor(hex: "#d33682"),
                NSColor(hex: "#2aa198"), NSColor(hex: "#eee8d5"),
                NSColor(hex: "#586e75"), NSColor(hex: "#cb4b16"),
                NSColor(hex: "#859900"), NSColor(hex: "#b58900"),
                NSColor(hex: "#268bd2"), NSColor(hex: "#6c71c4"),
                NSColor(hex: "#2aa198"), NSColor(hex: "#fdf6e3"),
            ]
        )
    )

    static let all: [AppTheme] = [
        .blueTitanium, .midnight, .solarizedDark, .rosePine, .light, .solarizedLight
    ]

    static func byId(_ id: String) -> AppTheme {
        all.first { $0.id == id } ?? .blueTitanium
    }
}

// MARK: - NSColor hex init

extension NSColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var int = UInt64()
        Scanner(string: hex).scanHexInt64(&int)
        let r = CGFloat((int >> 16) & 0xFF) / 255.0
        let g = CGFloat((int >> 8) & 0xFF) / 255.0
        let b = CGFloat(int & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}
