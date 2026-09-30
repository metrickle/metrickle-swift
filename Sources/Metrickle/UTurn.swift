/// A user lands on A, moves to B, and comes straight back to A. A short stay on B usually means B
/// was not what they expected. Port of `uturn.ts`.
public struct UTurn: Equatable, Sendable {
    /// The screen the user bounced off.
    public var from: String
    /// Where they went back to.
    public var to: String
    public var dwellMs: Int64
}

public struct UTurnDetector: Sendable {
    public static let defaultThresholdMs: Int64 = 7_000
    private let thresholdMs: Int64
    private var prev: (path: String, t: Int64)?
    private var cur: (path: String, t: Int64)?

    public init(thresholdMs: Int64 = UTurnDetector.defaultThresholdMs) { self.thresholdMs = thresholdMs }

    public mutating func visit(_ path: String, at now: Int64) -> UTurn? {
        if cur?.path == path { return nil }
        var hit: UTurn?
        if let prev, let cur, prev.path == path, now - cur.t < thresholdMs {
            hit = UTurn(from: cur.path, to: path, dwellMs: now - cur.t)
        }
        prev = cur
        cur = (path, now)
        return hit
    }
}
