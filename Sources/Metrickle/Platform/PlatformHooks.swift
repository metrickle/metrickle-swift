#if canImport(UIKit)
import GameController
import UIKit

@MainActor
enum PlatformHooks {
    static func start(_ client: Metrickle) {
        let (device, screen) = deviceContext()
        client.updateContext { ctx in
            ctx.device = device
            ctx.screen = screen
        }
        AccessibilityMonitor.start(client)

        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                // Settings can only change while the app is in the background.
                client.setA11y(AccessibilityMonitor.flags())
                client.appDidEnterForeground()
            }
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BackgroundFlush.run(client) }
        }

        if client.options.automaticScreenTracking { ScreenTracker.install() }
        if client.options.rageTaps { RageTapDetector.install() }
    }

    static func deviceContext() -> (EventContext.Device, EventContext.Screen) {
        let d = UIDevice.current
        let type: String
        switch d.userInterfaceIdiom {
        case .phone: type = "mobile"
        case .pad: type = "tablet"
        case .tv: type = "tv"
        default: type = "other"
        }
        let os = d.userInterfaceIdiom == .pad && !ProcessInfo.processInfo.isiOSAppOnMac ? "iPadOS" : "iOS"
        let size = UIScreen.main.fixedCoordinateSpace.bounds.size
        return (
            .init(type: type, model: PlatformInfo.modelIdentifier(), os: os, osVersion: d.systemVersion),
            .init(width: Int(size.width.rounded()), height: Int(size.height.rounded()))
        )
    }

    /// The key window of the foreground scene.
    static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.filter { $0.activationState == .foregroundActive }
        return (active.isEmpty ? scenes : active).flatMap(\.windows).first(where: \.isKeyWindow)
    }
}

/// Sends `$app_background` and everything queued inside a background task, so it isn't cut off by suspension.
@MainActor
final class BackgroundFlush {
    private var id: UIBackgroundTaskIdentifier = .invalid

    static func run(_ client: Metrickle) {
        let task = BackgroundFlush()
        task.id = UIApplication.shared.beginBackgroundTask(withName: "com.metrickle.flush") { task.end() }
        client.appDidEnterBackground { DispatchQueue.main.async { task.end() } }
    }

    private func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// Reads accessibility settings into `context.a11y` and follows their change notifications.
@MainActor
enum AccessibilityMonitor {
    static func flags() -> [String] {
        let keyboard = GCKeyboard.coalesced != nil || UIAccessibility.isSwitchControlRunning
        let checks: [(String, Bool)] = [
            ("screen_reader", UIAccessibility.isVoiceOverRunning),
            ("keyboard", keyboard),
            ("reduced_motion", UIAccessibility.isReduceMotionEnabled),
            ("reduced_transparency", UIAccessibility.isReduceTransparencyEnabled),
            ("high_contrast", UIAccessibility.isDarkerSystemColorsEnabled),
            ("inverted_colors", UIAccessibility.isInvertColorsEnabled),
            ("grayscale", UIAccessibility.isGrayscaleEnabled),
            ("bold_text", UIAccessibility.isBoldTextEnabled),
            ("large_text", UIApplication.shared.preferredContentSizeCategory > .large),
        ]
        return checks.filter(\.1).map(\.0)
    }

    static func start(_ client: Metrickle) {
        client.setA11y(flags())
        let names: [Notification.Name] = [
            UIAccessibility.voiceOverStatusDidChangeNotification,
            UIAccessibility.switchControlStatusDidChangeNotification,
            UIAccessibility.reduceMotionStatusDidChangeNotification,
            UIAccessibility.reduceTransparencyStatusDidChangeNotification,
            UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
            UIAccessibility.invertColorsStatusDidChangeNotification,
            UIAccessibility.grayscaleStatusDidChangeNotification,
            UIAccessibility.boldTextStatusDidChangeNotification,
            UIContentSizeCategory.didChangeNotification,
            .GCKeyboardDidConnect,
            .GCKeyboardDidDisconnect,
        ]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { client.setA11y(flags()) }
            }
        }
    }
}
#endif
