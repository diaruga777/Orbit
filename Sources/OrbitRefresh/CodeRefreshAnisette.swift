import Foundation
import AnisetteKit
import SideSign
import OrbitCore

/// The helper's ADI implementation and Apple's client identity must agree.
/// SideSign's pinned defaults predate the Mac ADI services and ignore client_info.
struct CodeRefreshAnisetteIdentity: Codable, Equatable, Sendable {
    let clientInfo: String
    let userAgent: String
    enum CodingKeys: String, CodingKey {
        case clientInfo = "client_info"
        case userAgent = "user_agent"
    }
    init(data: Data) throws {
        guard data.count <= 8192 else { throw CodeFailure("The sign-in helper returned invalid settings.") }
        self = try JSONDecoder().decode(Self.self, from: data)
        guard [clientInfo, userAgent].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else {
            throw CodeFailure("The sign-in helper returned invalid settings.")
        }
    }
    var headers: AnisetteRequestHeaders {
        var result = AnisetteRequestHeaders()
        result.clientInfo = clientInfo; result.userAgent = userAgent
        return result
    }
    func matches(_ data: AnisetteData) -> Bool { clientInfo == data.clientInfo && userAgent == data.userAgent }
}

struct CodeRefreshAnisette: Sendable {
    typealias Load = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias Fetch = @Sendable (URL, UUID, Data?, AnisetteRequestHeaders) async throws -> (AnisetteData, Data?)
    var load: Load = { request in
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await session.data(for: request)
    }
    var fetch: Fetch = { server, identifier, blob, headers in
        let manager = AnisetteDataManager(mode: .remote(server: server))
        return try await manager.fetchAnisetteData(identifier: identifier, existingAdiBlob: blob, headers: headers)
    }
    func data(server: URL, identifier: UUID, previous: CodeRefreshAccount?) async throws -> (data: AnisetteData, blob: Data?) {
        _ = try CodeRefreshSignInInput.serverURL(server.absoluteString)
        var request = URLRequest(url: server.appendingPathComponent("v3/client_info"))
        request.timeoutInterval = 20; request.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, response) = try await load(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.url == request.url else {
            throw CodeFailure("The sign-in helper is unavailable. Try again, or change it in Advanced.")
        }
        let identity = try CodeRefreshAnisetteIdentity(data: bytes)
        // Never feed a blob from another helper or ADI identity into provisioning.
        let existing = previous.flatMap { $0.anisetteURL == server && identity.matches($0.auth.session.anisetteData) ? $0.adiBlob : nil }
        try Task.checkCancellation()
        do {
            let (data, newBlob) = try await fetch(server, identifier, existing, identity.headers)
            return (data, newBlob ?? existing)
        } catch AnisetteError.badServerResponse(let status, _) where status == -1 && existing != nil {
            // A rejected cached ADI blob gets one fresh provisioning attempt on
            // the same service. Apple authentication is never retried here.
            try Task.checkCancellation()
            let (data, blob) = try await fetch(server, identifier, nil, identity.headers)
            return (data, blob)
        }
    }
    static func portal(for data: AnisetteData) -> DeveloperPortal {
        var headers = SideSignHeaders()
        headers.grandSlam.userAgent = data.userAgent
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        return DeveloperPortal(session: URLSession(configuration: configuration), customHeaders: headers)
    }
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
}
