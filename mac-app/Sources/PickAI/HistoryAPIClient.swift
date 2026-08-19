import Foundation

struct HistoryEntry: Decodable, Identifiable {
    let id: Int
    let created_at: String
    let mode: String
    let question: String?
    let answer: String
    let image_key: String?
}

enum HistorySortOrder: String {
    case asc, desc
}

enum HistoryAPIError: Error {
    case notSignedIn
    case unauthorized
    case http(Int)
}

/// Talks to the same pick-ai-history Worker the website uses. The Worker's CORS headers are
/// browser-only concerns — URLSession neither sends an Origin header for these requests nor
/// checks Access-Control-Allow-Origin, so they don't affect a native client at all.
enum HistoryAPIClient {
    static let baseURL = URL(string: "https://pick-ai-history.byeongminchoi12.workers.dev")!

    /// Fetches a fresh ID token every call — FirebaseRestAuth transparently refreshes it
    /// under the hood when it's close to expiring, so this never hands back a stale token.
    private static func authorizedRequest(url: URL) async throws -> URLRequest {
        guard let token = try await FirebaseRestAuth.currentIDToken() else {
            throw HistoryAPIError.notSignedIn
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func fetchHistory(
        query: String?,
        mode: String?,
        order: HistorySortOrder,
        cursorId: Int?
    ) async throws -> [HistoryEntry] {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/history"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "order", value: order.rawValue)]
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        if let mode, !mode.isEmpty { items.append(URLQueryItem(name: "mode", value: mode)) }
        if let cursorId { items.append(URLQueryItem(name: "cursorId", value: String(cursorId))) }
        components.queryItems = items

        let request = try await authorizedRequest(url: components.url!)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkStatus(response, expect: 200)
        return try JSONDecoder().decode([HistoryEntry].self, from: data)
    }

    static func deleteEntry(id: Int) async throws {
        var request = try await authorizedRequest(url: baseURL.appendingPathComponent("api/history/\(id)"))
        request.httpMethod = "DELETE"
        let (_, response) = try await URLSession.shared.data(for: request)
        try Self.checkStatus(response, expect: 204)
    }

    static func fetchImage(imageKey: String) async throws -> Data {
        let request = try await authorizedRequest(url: baseURL.appendingPathComponent("api/image/\(imageKey)"))
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkStatus(response, expect: 200)
        return data
    }

    private static func checkStatus(_ response: URLResponse, expect: Int) throws {
        guard let httpResponse = response as? HTTPURLResponse else { throw HistoryAPIError.http(-1) }
        if httpResponse.statusCode == 401 { throw HistoryAPIError.unauthorized }
        guard httpResponse.statusCode == expect else { throw HistoryAPIError.http(httpResponse.statusCode) }
    }
}
