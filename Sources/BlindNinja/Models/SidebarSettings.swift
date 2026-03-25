import Foundation

/// Visual style for session state indicators in the sidebar.
enum IndicatorStyle: String, CaseIterable {
    case dot = "dot"
    case ring = "ring"
    case bar = "bar"
    case glow = "glow"
    case none = "none"

    var displayName: String {
        switch self {
        case .dot: return "Dot"
        case .ring: return "Ring"
        case .bar: return "Bar"
        case .glow: return "Glow"
        case .none: return "None"
        }
    }
}

/// Controls row height, font size, and spacing density.
enum SidebarDensity: String, CaseIterable {
    case compact = "compact"
    case `default` = "default"
    case comfortable = "comfortable"
    case spacious = "spacious"

    var displayName: String {
        switch self {
        case .compact: return "Compact"
        case .default: return "Default"
        case .comfortable: return "Comfortable"
        case .spacious: return "Spacious"
        }
    }

    var rowHeight: CGFloat {
        switch self {
        case .compact: return 28
        case .default: return 34
        case .comfortable: return 42
        case .spacious: return 52
        }
    }

    var branchRowHeight: CGFloat {
        switch self {
        case .compact: return 36
        case .default: return 44
        case .comfortable: return 52
        case .spacious: return 64
        }
    }

    var sectionHeaderHeight: CGFloat {
        switch self {
        case .compact: return 20
        case .default: return 24
        case .comfortable: return 30
        case .spacious: return 36
        }
    }

    var nameFontSize: CGFloat {
        switch self {
        case .compact: return 11
        case .default: return 12
        case .comfortable: return 13
        case .spacious: return 15
        }
    }

    var branchFontSize: CGFloat {
        switch self {
        case .compact: return 8
        case .default: return 9
        case .comfortable: return 10
        case .spacious: return 11
        }
    }

    var dotSize: CGFloat {
        switch self {
        case .compact: return 6
        case .default: return 7
        case .comfortable: return 9
        case .spacious: return 11
        }
    }

    var barWidth: CGFloat {
        switch self {
        case .compact: return 2
        case .default: return 2.5
        case .comfortable: return 3
        case .spacious: return 4
        }
    }

    var intercellSpacing: CGFloat {
        switch self {
        case .compact: return 0
        case .default: return 1
        case .comfortable: return 2
        case .spacious: return 4
        }
    }
}

/// Reads/writes sidebar appearance preferences from UserDefaults.
struct SidebarSettings {
    private static let indicatorKey = "sidebarIndicatorStyle"
    private static let densityKey = "sidebarDensity"

    static var indicatorStyle: IndicatorStyle {
        get {
            guard let raw = UserDefaults.standard.string(forKey: indicatorKey) else { return .bar }
            return IndicatorStyle(rawValue: raw) ?? .bar
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: indicatorKey) }
    }

    static var density: SidebarDensity {
        get {
            guard let raw = UserDefaults.standard.string(forKey: densityKey) else { return .comfortable }
            return SidebarDensity(rawValue: raw) ?? .comfortable
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: densityKey) }
    }
}
