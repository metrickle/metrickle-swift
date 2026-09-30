import Foundation
import XCTest
@testable import Metrickle

/// Records requests. Batch statuses are consumed in order (default 200); -1 simulates a network error.
final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var statuses: [Int]
    var config: Data?

    init(statuses: [Int] = [], config: Data? = nil) {
        self.statuses = statuses
        self.config = config
    }

    var requests: [URLRequest] { lock.withLock { _requests } }

    var batches: [IngestBatch] {
        requests.filter { $0.url?.path == "/v1/batch" }.compactMap { $0.httpBody }.compactMap {
            try? JSONDecoder().decode(IngestBatch.self, from: $0)
        }
    }

    var events: [Event] { batches.flatMap(\.events) }

    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        lock.withLock { _requests.append(request) }
        switch request.url?.path {
        case "/v1/config":
            return config.map { (200, $0) } ?? (404, Data())
        case "/v1/feedback":
            return (201, Data(#"{"id":"fb_1"}"#.utf8))
        default:
            let status = lock.withLock { statuses.isEmpty ? 200 : statuses.removeFirst() }
            if status == -1 { throw URLError(.notConnectedToInternet) }
            return (status, Data())
        }
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64
    init(_ start: Int64 = 1_700_000_000_000) { value = start }
    var now: Int64 { lock.withLock { value } }
    func advance(_ ms: Int64) { lock.withLock { value += ms } }
    func set(_ ms: Int64) { lock.withLock { value = ms } }
}

func makeClient(
    storage: MetrickleStorage? = MemoryStorage(),
    transport: RecordingTransport = RecordingTransport(),
    clock: TestClock? = nil,
    options: Metrickle.Options = Metrickle.Options(flushInterval: 3600),
    fetchConfig: Bool = false
) -> Metrickle {
    let context = EventContext(
        library: .init(name: Metrickle.libraryName, version: Metrickle.sdkVersion), platform: "ios",
        app: .init(version: "2.4.1", build: "241"),
        device: .init(type: "mobile", model: "iPhone15,2", os: "iOS", osVersion: "17.2"),
        screen: .init(width: 393, height: 852), locale: "en-GB", timezone: "Europe/London"
    )
    let client: Metrickle
    if let clock {
        client = Metrickle(writeKey: "k", options: options, storage: storage, transport: transport, context: context,
                           clock: { clock.now }, fetchConfig: fetchConfig)
    } else {
        client = Metrickle(writeKey: "k", options: options, storage: storage, transport: transport, context: context,
                           fetchConfig: fetchConfig)
    }
    return client
}

extension Metrickle {
    @discardableResult
    func flushNow() async -> Bool {
        await withCheckedContinuation { cont in flush { cont.resume(returning: $0) } }
    }

    /// The background flush: everything, ignoring backoff.
    @discardableResult
    func flushAll() async -> Bool {
        await withCheckedContinuation { cont in q.async { self.flushLocked(force: true) { cont.resume(returning: $0) } } }
    }
}

func sleep(ms: Int) async { try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }
