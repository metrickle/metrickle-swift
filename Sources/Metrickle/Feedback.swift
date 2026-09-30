import Foundation

/// "Report a problem" submissions: `Metrickle.shared?.feedback`.
public final class Feedback: @unchecked Sendable {
    weak var client: Metrickle?

    /// Max decoded screenshot size accepted by `POST /v1/feedback`.
    static let maxScreenshotBytes = 2 * 1024 * 1024

    /// False when feedback is switched off for iOS in the dashboard; `submit` then sends nothing. Use it to hide your
    /// own feedback button.
    public var isEnabled: Bool { client?.feedbackEnabled.get() ?? false }

    /// Sends a report. Session, screen, device, app version, locale and accessibility context are attached so it links to
    /// the user's journey. `screenshot` is a `data:image/png|jpeg;base64,…` URL, e.g. from `captureScreenshot()`.
    /// `rating` is 1–5. Returns the server's id on success. Nothing is sent after `optOut()` or while `isEnabled` is false.
    public func submit(category: FeedbackCategory, message: String, rating: Int? = nil, screenshot: String? = nil,
                       path: String? = nil) async -> (ok: Bool, id: String?) {
        guard let client, client.feedbackEnabled.get() else { return (false, nil) }
        let message = truncate(message.trimmingCharacters(in: .whitespacesAndNewlines), 4000)
        guard !message.isEmpty else { return (false, nil) }
        let body: FeedbackSubmission? = await withCheckedContinuation { cont in
            client.q.async {
                guard !client.optedOut else { return cont.resume(returning: nil) }
                let ctx = client.context
                let id = client.identity
                cont.resume(returning: FeedbackSubmission(
                    writeKey: client.writeKey, anonymousId: id.anonymousId, userId: id.userId, sessionId: id.sessionId,
                    category: category, message: message, rating: rating.flatMap { (1...5).contains($0) ? $0 : nil },
                    url: nil, path: path ?? client.currentScreen, platform: Metrickle.platform, appVersion: ctx.app?.version,
                    device: ctx.device.map { .init(type: $0.type, os: $0.os, model: $0.model) },
                    screen: ctx.screen, locale: ctx.locale, a11y: ctx.a11y, screenshot: screenshot
                ))
            }
        }
        guard let body, let data = try? JSONEncoder().encode(body), let url = URL(string: "\(client.host)/v1/feedback") else {
            return (false, nil)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(client.writeKey, forHTTPHeaderField: "x-metrickle-key")
        req.setValue(client.onQueue { client.userAgent }, forHTTPHeaderField: "User-Agent")
        guard let (status, response) = try? await client.transport.send(req), (200..<300).contains(status) else {
            return (false, nil)
        }
        struct Created: Decodable { var id: String? }
        return (true, (try? JSONDecoder().decode(Created.self, from: response))?.id)
    }
}
