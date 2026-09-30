import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum PlatformInfo {
    /// Context that can be read on any thread. Device type, OS name and screen size are filled in on the main thread.
    static func baseContext(_ options: Metrickle.Options) -> EventContext {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = options.appVersion ?? (info["CFBundleShortVersionString"] as? String)
        let build = options.appBuild ?? (info["CFBundleVersion"] as? String)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if canImport(UIKit)
        let os = "iOS"
        #else
        let os = "macOS"
        #endif
        return EventContext(
            library: .init(name: Metrickle.libraryName, version: Metrickle.sdkVersion),
            platform: Metrickle.platform,
            app: .init(version: version, build: build),
            device: .init(
                type: "other", model: modelIdentifier(), os: os,
                osVersion: v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
            ),
            screen: nil,
            locale: locale(),
            timezone: TimeZone.current.identifier
        )
    }

    /// Hardware model identifier, e.g. `iPhone15,2` (the simulated one on a simulator). Not a device identifier.
    static func modelIdentifier() -> String? {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var u = utsname()
        uname(&u)
        let id = withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return id.isEmpty ? nil : id
    }

    /// BCP 47 tag of the current locale, e.g. `en-GB`.
    static func locale() -> String? {
        let l = Locale.current
        guard let lang = l.languageCode else { return nil }
        let tag = [lang, l.scriptCode, l.regionCode].compactMap { $0 }.joined(separator: "-")
        return truncate(tag, 35)
    }
}

extension Metrickle {
    /// Starts platform integrations (lifecycle, accessibility, screen and rage-tap tracking) on the main thread.
    func startPlatform() {
        captureAsync(.track, "$app_open")
        #if canImport(UIKit)
        if Thread.isMainThread {
            MainActor.assumeIsolated { PlatformHooks.start(self) }
        } else {
            DispatchQueue.main.async { PlatformHooks.start(self) }
        }
        #endif
    }
}
