import Foundation

/// HTTP abstraction so tests can record requests. Returns the status code and body, or throws on a network error.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.urlCache = nil
            config.timeoutIntervalForRequest = 30
            return URLSession(configuration: config)
        }()
    }

    public func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

enum HTTP {
    /// A 2xx, or a 4xx other than 429, means done: a bad batch will never succeed.
    static func isDone(_ status: Int) -> Bool {
        (200..<300).contains(status) || ((400..<500).contains(status) && status != 429)
    }
}
