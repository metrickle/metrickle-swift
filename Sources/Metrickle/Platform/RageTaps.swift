#if canImport(UIKit)
import UIKit

/// Detects 3 taps within 1s inside a 30pt box (same as the web SDK) by observing `UIWindow.sendEvent(_:)`.
/// Events are passed through untouched; drags are ignored.
@MainActor
final class RageTapDetector {
    static let shared = RageTapDetector()
    private static var installed = false

    /// Where each touch began, and the view it began on (UIKit can clear `touch.view` by the time it ends).
    private var starts: [ObjectIdentifier: (p: CGPoint, view: UIView?)] = [:]
    private var taps: [(t: TimeInterval, p: CGPoint)] = []

    static func install() {
        guard !installed else { return }
        installed = true
        swizzle(UIWindow.self, #selector(UIWindow.sendEvent(_:)), #selector(UIWindow.mk_sendEvent(_:)))
    }

    func handle(_ event: UIEvent, in window: UIWindow) {
        guard event.type == .touches, let touches = event.allTouches else { return }
        for touch in touches where touch.window === window {
            let id = ObjectIdentifier(touch)
            let p = touch.location(in: window)
            switch touch.phase {
            case .began:
                starts[id] = (p, touch.view)
            case .ended:
                guard let start = starts.removeValue(forKey: id), hypot(p.x - start.p.x, p.y - start.p.y) < 10 else { continue }
                tap(at: p, time: touch.timestamp, view: touch.view ?? start.view ?? window.hitTest(p, with: nil))
            case .cancelled:
                starts[id] = nil
            default:
                break
            }
        }
    }

    private func tap(at p: CGPoint, time: TimeInterval, view: UIView?) {
        taps = taps.filter { time - $0.t < 1 && abs($0.p.x - p.x) < 30 && abs($0.p.y - p.y) < 30 }
        taps.append((time, p))
        guard taps.count == 3, let client = Metrickle.shared, client.options.rageTaps else { return }
        let (selector, text) = Self.describe(view)
        client.captureAsync(.track, "$rage_click", properties: ["selector": .string(selector), "text": text.map { .string($0) } ?? .null])
    }

    /// Selector: the nearest accessibility identifier, else the class name of the nearest view with an identifier or label.
    /// Text: that view's accessibility label (≤ 80), never anything inside a text input.
    static func describe(_ hit: UIView?) -> (selector: String, text: String?) {
        var target = hit
        var inTextInput = false
        var v = hit
        var found = false
        while let cur = v {
            if cur is UITextInput || cur is UISearchBar { inTextInput = true }
            if !found, nonEmpty(cur.accessibilityIdentifier) != nil || nonEmpty(cur.accessibilityLabel) != nil {
                target = cur
                found = true
            }
            v = cur.superview
        }
        let selector = nonEmpty(target?.accessibilityIdentifier) ?? target.map { String(describing: type(of: $0)) } ?? "unknown"
        let text = inTextInput ? nil : label(of: target).map { truncate($0, 80) }
        return (truncate(selector, 256), text)
    }

    /// UIKit only fills in default accessibility labels while assistive tech is running, so fall back to visible titles.
    private static func label(of view: UIView?) -> String? {
        guard let view else { return nil }
        if let l = nonEmpty(view.accessibilityLabel) { return l }
        if let b = view as? UIButton { return nonEmpty(b.currentTitle) ?? nonEmpty(b.titleLabel?.text) }
        if let l = view as? UILabel { return nonEmpty(l.text) }
        return nil
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}

extension UIWindow {
    @objc dynamic func mk_sendEvent(_ event: UIEvent) {
        mk_sendEvent(event) // the original, after swizzling
        RageTapDetector.shared.handle(event, in: self)
    }
}
#endif
