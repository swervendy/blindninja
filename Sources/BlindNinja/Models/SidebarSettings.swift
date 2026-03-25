import Foundation

/// Visual style for session state indicators in the sidebar.
enum IndicatorStyle: String, CaseIterable {
    case dot = "dot"
    case ring = "ring"
    case bar = "bar"

    var displayName: String {
        switch self {
        case .dot: return "Dot"
        case .ring: return "Ring"
        case .bar: return "Bar"
        }
    }
}

/// Controls row height, font size, and spacing density.
enum SidebarDensity: String, CaseIterable {
    case compact = "compact"
    case `default` = "default"
    case comfortable = "comfortable"

    var displayName: String {
        switch self {
        case .compact: return "Compact"
        case .default: return "Default"
        case .comfortable: return "Comfortable"
        }
    }

    var rowHeight: CGFloat {
        switch self {
        case .compact: return 30
        case .default: return 38
        case .comfortable: return 46
        }
    }

    var branchRowHeight: CGFloat {
        switch self {
        case .compact: return 38
        case .default: return 48
        case .comfortable: return 56
        }
    }

    var sectionHeaderHeight: CGFloat {
        switch self {
        case .compact: return 22
        case .default: return 28
        case .comfortable: return 32
        }
    }

    var nameFontSize: CGFloat {
        switch self {
        case .compact: return 11
        case .default: return 13
        case .comfortable: return 14
        }
    }

    var branchFontSize: CGFloat {
        switch self {
        case .compact: return 8
        case .default: return 9
        case .comfortable: return 10
        }
    }

    var dotSize: CGFloat {
        switch self {
        case .compact: return 6
        case .default: return 8
        case .comfortable: return 10
        }
    }

    var barWidth: CGFloat {
        switch self {
        case .compact: return 2.5
        case .default: return 3
        case .comfortable: return 3.5
        }
    }

    var intercellSpacing: CGFloat {
        switch self {
        case .compact: return 1
        case .default: return 2
        case .comfortable: return 3
        }
    }
}

/// Reads/writes sidebar appearance preferences from UserDefaults.
struct SidebarSettings {
    private static let indicatorKey = "sidebarIndicatorStyle"
    private static let densityKey = "sidebarDensity"

    static var indicatorStyle: IndicatorStyle {
        get {
            guard let raw = UserDefaults.standard.string(forKey: indicatorKey) else { return .dot }
            return IndicatorStyle(rawValue: raw) ?? .dot
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: indicatorKey) }
    }

    static var density: SidebarDensity {
        get {
            guard let raw = UserDefaults.standard.string(forKey: densityKey) else { return .default }
            return SidebarDensity(rawValue: raw) ?? .default
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: densityKey) }
    }
}
