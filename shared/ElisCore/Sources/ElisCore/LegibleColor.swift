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

    public static func composite(_ layer: RGBA, over under: RGBA) -> RGBA {
        let a = layer.a + under.a * (1 - layer.a)
        guard a > 0 else { return RGBA(r: 0, g: 0, b: 0, a: 0) }
        func mix(_ l: Double, _ u: Double) -> Double {
            (l * layer.a + u * under.a * (1 - layer.a)) / a
        }
        return RGBA(r: mix(layer.r, under.r), g: mix(layer.g, under.g), b: mix(layer.b, under.b), a: a)
    }

    /// WCAG relative luminance of the RGB channels; alpha is ignored.
    public static func luminance(_ c: RGBA) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }
}

func contrast(_ color: RGBA, over bg: RGBA) -> Double {
    let a = RGBA.luminance(RGBA.composite(color, over: bg)), b = RGBA.luminance(bg)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

/// Moves `color` toward white on a dark first backdrop, black on a light one, until it reaches 4.5:1 on every
/// backdrop; returns `text` if no step does. Mixing toward a pole, not the text color, keeps the hue.
public func legibleOn(_ color: RGBA, under: [RGBA], text: RGBA) -> RGBA {
    guard let base = under.first else { return color }
    let white = RGBA(r: 1, g: 1, b: 1), black = RGBA(r: 0, g: 0, b: 0)
    let pole = contrast(white, over: base) > contrast(black, over: base) ? white : black
    for step in 0...20 {
        let t = Double(step) / 20
        let candidate = RGBA(
            r: color.r + (pole.r - color.r) * t,
            g: color.g + (pole.g - color.g) * t,
            b: color.b + (pole.b - color.b) * t,
            a: color.a)
        if under.allSatisfy({ contrast(candidate, over: $0) >= 4.5 }) { return candidate }
    }
    return text
}
