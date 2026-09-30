import Foundation

/// Key/value persistence. Implementations must be thread safe.
public protocol MetrickleStorage: Sendable {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String)
    func remove(_ key: String)
}

/// Persistence in the `com.metrickle` UserDefaults suite (removed with the app).
public struct UserDefaultsStorage: MetrickleStorage {
    public static let suiteName = "com.metrickle"
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(suiteName: String = UserDefaultsStorage.suiteName) {
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    public func get(_ key: String) -> String? { defaults.string(forKey: key) }
    public func set(_ key: String, _ value: String) { defaults.set(value, forKey: key) }
    public func remove(_ key: String) { defaults.removeObject(forKey: key) }
}

/// In-memory storage, for tests and previews.
public final class MemoryStorage: MetrickleStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: [String: String]

    public init(_ data: [String: String] = [:]) { self.data = data }

    public func get(_ key: String) -> String? { lock.withLock { data[key] } }
    public func set(_ key: String, _ value: String) { lock.withLock { data[key] = value } }
    public func remove(_ key: String) { lock.withLock { _ = data.removeValue(forKey: key) } }
}

enum Keys {
    static let anon = "mk_aid"
    static let user = "mk_uid"
    static let session = "mk_sid"
    static let optOut = "mk_optout"
    static let consent = "mk_consent"
    static let surveys = "mk_surveys"
    static let queue = "mk_queue"
}

/// A thread-safe box for values read from any thread.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ v: Value) { lock.withLock { value = v } }
    @discardableResult func update<R>(_ fn: (inout Value) -> R) -> R { lock.withLock { fn(&value) } }
}
