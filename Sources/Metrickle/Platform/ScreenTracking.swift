#if canImport(SwiftUI)
import SwiftUI

public extension View {
    /// Records a `$screen` named `name` each time this view appears. Use on the root view of each SwiftUI screen.
    func metrickleScreen(_ name: String, properties: Properties? = nil) -> some View {
        onAppear { Metrickle.shared?.screen(name, properties: properties) }
    }
}
#endif

#if canImport(UIKit)
import ObjectiveC
import UIKit

/// Adopt on a view controller to name its screen for automatic tracking. Return nil to skip it.
@MainActor
public protocol MetrickleScreenNaming {
    var metrickleScreenName: String? { get }
}

@MainActor
enum ScreenTracker {
    private static var installed = false

    /// Swizzles `UIViewController.viewDidAppear(_:)` once.
    static func install() {
        guard !installed else { return }
        installed = true
        swizzle(UIViewController.self, #selector(UIViewController.viewDidAppear(_:)), #selector(UIViewController.mk_viewDidAppear(_:)))
    }

    static func didAppear(_ vc: UIViewController) {
        guard let client = Metrickle.shared, client.options.automaticScreenTracking, let name = name(for: vc) else { return }
        client.screen(name)
    }

    /// `title`, else the class name without its "ViewController" suffix. Nil for containers, system and private
    /// controllers, and generic ones such as `UIHostingController<Content>` (use `.metrickleScreen` in SwiftUI).
    static func name(for vc: UIViewController) -> String? {
        if let named = vc as? MetrickleScreenNaming { return named.metrickleScreenName }
        if vc is UINavigationController || vc is UITabBarController || vc is UIPageViewController
            || vc is UISplitViewController || vc is SurveyHostingController { return nil }
        let cls: AnyClass = type(of: vc)
        let name = String(describing: cls)
        if name.hasPrefix("_") || name.contains("<") || !isAppClass(cls) { return nil }
        if let title = vc.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        let suffix = "ViewController"
        return name.hasSuffix(suffix) && name.count > suffix.count ? String(name.dropLast(suffix.count)) : name
    }

    /// Classes from the app bundle (including its embedded frameworks), as opposed to UIKit, SwiftUI and other system frameworks.
    private static func isAppClass(_ cls: AnyClass) -> Bool {
        let path = Bundle(for: cls).bundleURL.resolvingSymlinksInPath().path
        return path.hasPrefix(Bundle.main.bundleURL.resolvingSymlinksInPath().path)
    }
}

extension UIViewController {
    @objc dynamic func mk_viewDidAppear(_ animated: Bool) {
        mk_viewDidAppear(animated) // the original, after swizzling
        ScreenTracker.didAppear(self)
    }
}

func swizzle(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
    guard let a = class_getInstanceMethod(cls, original), let b = class_getInstanceMethod(cls, replacement) else { return }
    if class_addMethod(cls, original, method_getImplementation(b), method_getTypeEncoding(b)) {
        class_replaceMethod(cls, replacement, method_getImplementation(a), method_getTypeEncoding(a))
    } else {
        method_exchangeImplementations(a, b)
    }
}
#endif
