import Foundation

/// WCAG 2.x contrast ratio between two #rrggbb colours (1 to 21). Port of `contrastRatio` in `@metrickle/schema`.
public func contrastRatio(_ a: String, _ b: String) -> Double {
    let x = relativeLuminance(a), y = relativeLuminance(b)
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}

/// Text colour for a brand fill: white when it reaches 4.5:1, otherwise black.
public func textOn(_ fill: String) -> String {
    contrastRatio(fill, "#ffffff") >= 4.5 ? "#ffffff" : "#000000"
}

func relativeLuminance(_ hex: String) -> Double {
    let (r, g, b) = rgb(hex) ?? (0, 0, 0)
    func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
}

/// Components 0–1 of a #rrggbb string.
func rgb(_ hex: String) -> (Double, Double, Double)? {
    let s = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
    return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
}

func hexString(r: Double, g: Double, b: Double) -> String {
    func c(_ x: Double) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
    return String(format: "#%02x%02x%02x", c(r), c(g), c(b))
}
