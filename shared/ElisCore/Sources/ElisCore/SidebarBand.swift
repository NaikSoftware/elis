/// Where a row sits in its workspace group's tint band, which rounds and insets only the group's outer edges.
public enum SidebarBandEdge: Sendable, Equatable {
    case single, first, middle, last
}

/// The two hex colors of an active row's wave.
public struct SidebarWave: Sendable, Equatable {
    public let base: String
    public let second: String

    public init(base: String, second: String) {
        self.base = base
        self.second = second
    }
}

public enum SidebarBand {
    /// edge is where row `index` of a group of `count` rows sits; an out-of-range index clamps into the group.
    public static func edge(index: Int, count: Int) -> SidebarBandEdge {
        guard count > 1 else { return .single }
        switch min(max(index, 0), count - 1) {
        case 0: return .first
        case count - 1: return .last
        default: return .middle
        }
    }

    /// wave shows for an active agent or an unblocked indeterminate progress.
    /// A tinted base pairs with the active color, an untinted one with the accent.
    public static func wave(status: AgentStatus, indeterminate: Bool = false, sessionTintHex: String?,
                            workspaceTintHex: String?, activeHex: String, accentHex: String) -> SidebarWave? {
        guard status == .active || (indeterminate && status != .blocked) else { return nil }
        guard let tint = sessionTintHex ?? workspaceTintHex else { return SidebarWave(base: activeHex, second: accentHex) }
        return SidebarWave(base: tint, second: activeHex)
    }

    /// progressFill is nil for no or indeterminate progress and for a blocked row; the fraction clamps to 0...1.
    public static func progressFill(progress: SessionProgress?, status: AgentStatus, sessionTintHex: String?,
                                    workspaceTintHex: String?, activeHex: String) -> SidebarProgressFill? {
        guard status != .blocked, let fraction = progress?.fraction else { return nil }
        return SidebarProgressFill(colorHex: sessionTintHex ?? workspaceTintHex ?? activeHex,
                                   fraction: min(max(fraction, 0), 1))
    }
}

/// The share of a row's width a determinate progress fills, and its color.
public struct SidebarProgressFill: Sendable, Equatable {
    public let colorHex: String
    public let fraction: Double
    public static let alpha = 0.16

    public init(colorHex: String, fraction: Double) {
        self.colorHex = colorHex
        self.fraction = fraction
    }
}
