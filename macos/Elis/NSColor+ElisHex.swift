import AppKit
import ElisCore

extension NSColor {
    /// Parse a `#RRGGBB` (or bare `RRGGBB`) hex string into an sRGB color. Returns nil for nil or
    /// malformed input, so callers can fall back to a default.
    convenience init?(elisHex hex: String?) {
        guard let hex else { return nil }
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// The color as a `#RRGGBB` sRGB hex string (alpha dropped). nil if it can't be expressed in sRGB.
    var elisHexString: String? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

extension NSColor {
    /// rgba is the color in sRGB for ElisCore's contrast math; resolve a dynamic color under the drawing appearance.
    var rgba: RGBA {
        guard let c = usingColorSpace(.sRGB) else { return RGBA(r: 0, g: 0, b: 0) }
        return RGBA(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
    }

    convenience init(_ rgba: RGBA) {
        self.init(srgbRed: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
    }
}
