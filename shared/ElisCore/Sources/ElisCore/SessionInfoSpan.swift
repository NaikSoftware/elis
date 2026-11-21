import Foundation

/// SessionInfoSpan is one styled run of a session's sidebar info line. Host-free, so the app maps it to fonts and colors.
public struct SessionInfoSpan: Equatable, Sendable {
    public var text: String
    public var bold = false
    public var italic = false
    public var code = false
    public var dim = false
    public var color: TintColor?

    public init(text: String, bold: Bool = false, italic: Bool = false, code: Bool = false, dim: Bool = false,
                color: TintColor? = nil) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.code = code
        self.dim = dim
        self.color = color
    }
}
