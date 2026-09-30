#if canImport(UIKit)
import UIKit

extension Feedback {
    /// Captures the key window as a `data:image/jpeg;base64,…` URL (quality 0.7, long edge ≤ 1280px, ≤ 2 MB) for `submit`.
    /// Only call this after the user chose to attach a screenshot: it may contain personal data. Text fields are not masked.
    @MainActor
    public func captureScreenshot() -> String? {
        guard let window = PlatformHooks.keyWindow() else { return nil }
        let bounds = window.bounds
        let longEdge = max(bounds.width, bounds.height)
        guard longEdge > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(window.screen.scale, 1280 / longEdge)
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
        var quality: CGFloat = 0.7
        var data = image.jpegData(compressionQuality: quality)
        while let d = data, d.count > Self.maxScreenshotBytes, quality > 0.3 {
            quality -= 0.2
            data = image.jpegData(compressionQuality: quality)
        }
        guard let data, data.count <= Self.maxScreenshotBytes else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }
}
#endif
