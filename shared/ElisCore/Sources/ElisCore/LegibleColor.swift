import Foundation

public struct RGBA: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    static func composite(_ layer: RGBA, over under: RGBA) -> RGBA {
        let a = layer.a + under.a * (1 - layer.a)
        guard a > 0 else { return RGBA(r: 0, g: 0, b: 0, a: 0) }
        func mix(_ l: Double, _ u: Double) -> Double {
            (l * layer.a + u * under.a * (1 - layer.a)) / a
        }
        return RGBA(r: mix(layer.r, under.r), g: mix(layer.g, under.g), b: mix(layer.b, under.b), a: a)
    }

    /// WCAG relative luminance of the RGB channels; alpha is ignored.
    static func luminance(_ c: RGBA) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }
}

/// Moves `color` toward `text` until it reaches 4.5:1 on every backdrop; returns `text` if no step does.
public func legibleOn(_ color: RGBA, under: [RGBA], text: RGBA) -> RGBA {
    for step in 0...20 {
        let t = Double(step) / 20
        let candidate = RGBA(
            r: color.r + (text.r - color.r) * t,
            g: color.g + (text.g - color.g) * t,
            b: color.b + (text.b - color.b) * t,
            a: color.a)
        let passes = under.allSatisfy { bg in
            let a = RGBA.luminance(RGBA.composite(candidate, over: bg))
            let b = RGBA.luminance(bg)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05) >= 4.5
        }
        if passes { return candidate }
    }
    return text
}
