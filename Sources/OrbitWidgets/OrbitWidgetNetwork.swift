import Foundation

/// No shared cookies, credential store, or inherited URLSession cache. Redirects
/// must satisfy the same exact-host grant as the original request.
final class OrbitWidgetNetwork: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let definition: OrbitWidgetDefinition
    private let completion: @Sendable (Result<(Int, Data), Error>) -> Void
    private let sessionLock = NSLock()
    private var session: URLSession?
    private var bytes = Data()
    private var status = 0
    private var failure: Error?
    init(definition: OrbitWidgetDefinition, completion: @escaping @Sendable (Result<(Int, Data), Error>) -> Void) {
        self.definition = definition; self.completion = completion
    }
    func start(url: String, options: [String: Any]) throws {
        guard let url = URL(string: url), definition.permits(url) else { throw OrbitWidgetError("This address isn’t in the widget’s allowed HTTPS domains.") }
        let method = (options["method"] as? String ?? "GET").uppercased()
        let body = (options["body"] as? String).map { Data($0.utf8) }
        guard ["GET", "POST"].contains(method), (body?.count ?? 0) <= 16 * 1024 else { throw OrbitWidgetError("Widget requests support GET or POST with a small body.") }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 10
        if let headers = options["headers"] as? [String: String] {
            guard headers.count <= 16, headers.allSatisfy({ $0.key.count <= 80 && $0.value.count <= 4096 && !["host", "cookie", "content-length", "connection"].contains($0.key.lowercased()) }) else { throw OrbitWidgetError("Unsupported request headers.") }
            request.allHTTPHeaderFields = headers
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10; configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        sessionLock.lock(); self.session = session; sessionLock.unlock()
        session.dataTask(with: request).resume()
    }
    func cancel() {
        sessionLock.lock(); let session = self.session; sessionLock.unlock()
        session?.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, definition.permits(url), response.url?.host == url.host else {
            failure = OrbitWidgetError("The widget’s request redirected to a different domain."); completionHandler(nil); return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.expectedContentLength <= 1024 * 1024 else {
            failure = OrbitWidgetError("The widget’s response was too large."); completionHandler(.cancel); return
        }
        status = response.statusCode; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard bytes.count + data.count <= 1024 * 1024 else { failure = OrbitWidgetError("The widget’s response was too large."); dataTask.cancel(); return }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = failure ?? error { completion(.failure(error)) } else { completion(.success((status, bytes))) }
        session.finishTasksAndInvalidate()
        sessionLock.lock(); self.session = nil; sessionLock.unlock()
    }
}
