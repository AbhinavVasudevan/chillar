import Foundation

/// Hardened HTTPS client shared by broker adapters.
/// - Ephemeral: no on-disk cache or cookies, so account data never lands on disk.
/// - Redirects are refused, so credential headers can't be forwarded to another host.
/// - Requests are pinned to the adapter's API host.
/// - 10s idle and 20s total timeouts, so a stalled request can't hang the UI.
final class HTTPClient: Sendable {
    let host: String
    private let session: URLSession

    init(host: String) {
        self.host = host
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.tlsMinimumSupportedProtocolVersion = .TLSv12
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 20
        session = URLSession(configuration: c, delegate: RedirectBlocker(), delegateQueue: nil)
    }

    /// Cancels in-flight requests; the session (which retains its delegate) is then released.
    func invalidate() { session.invalidateAndCancel() }

    /// Sends `req` and returns the body for a 2xx response; throws `BrokerError` otherwise.
    /// A cancelled request throws `CancellationError`.
    func send(_ req: URLRequest, errorMessage: (Data) -> String? = { _ in nil }) async throws -> Data {
        guard req.url?.scheme == "https", req.url?.host == host else { throw BrokerError.invalidResponse }
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300: return data
        case 401, 403: throw BrokerError.unauthorized
        default: throw BrokerError.http(code, errorMessage(data))
        }
    }
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
