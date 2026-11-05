import Foundation

public enum CloudError: LocalizedError, Sendable, Equatable {
    /// 401/403 — the cached credential is no longer accepted.
    case unauthorized
    case http(status: Int, code: String)
    case rejected(code: String)
    case transport(String)
    case invalidResponse
    case notConnected
    case notFound
    case invalidInput(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "Samsung Cloud rejected the stored credential. Reconnect to continue."
        case .http(let status, let code): return "Samsung Cloud HTTP \(status), code \(code)."
        case .rejected(let code): return "Samsung Cloud rejected the record, code \(code)."
        case .transport(let message): return "Network error: \(message)"
        case .invalidResponse: return "Samsung Cloud returned an unreadable response."
        case .notConnected: return "No Samsung account is connected."
        case .notFound: return "The reminder no longer exists in Samsung Cloud."
        case .invalidInput(let message): return message
        }
    }
}

/// Direct client for Samsung Cloud's generic record store, the same four
/// headers and endpoints the reference desktop client uses.
/// Protocol constants only — no account data lives here.
public struct SamsungCloudClient: Sendable {
    public static let baseURL = URL(string: "https://api.samsungcloud.com")!
    static let appID = "8o8b82h22a"
    public static let reminderTable = "com.samsung.android.app.reminder"
    public static let categoryTable = "com.samsung.android.app.reminder.category"
    /// One page is Samsung's hard cap; chunk size is the `/get` body limit.
    public static let pageLimit = 500
    static let getChunk = 100

    let credential: CloudCredential
    let session: URLSession

    public init(credential: CloudCredential, session: URLSession = .cloud) {
        self.credential = credential
        self.session = session
    }

    public struct ListedRecord: Sendable, Hashable {
        public let id: String
        public let modTimestamp: Int64
    }

    public struct Listing: Sendable {
        public let records: [ListedRecord]
        public let hasMore: Bool
    }

    // MARK: Requests

    func request(_ method: String, path: String, query: [URLQueryItem], body: JSONValue? = nil) async throws -> JSONValue {
        var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        components.queryItems = query
        guard let url = components.url, url.host == Self.baseURL.host, url.scheme == "https" else {
            throw CloudError.invalidResponse
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue(credential.userId, forHTTPHeaderField: "x-sc-uid")
        request.setValue(credential.accessToken, forHTTPHeaderField: "x-sc-access-token")
        request.setValue(Self.appID, forHTTPHeaderField: "x-sc-app-id")
        request.setValue(credential.deviceId, forHTTPHeaderField: "x-sc-dvc-id")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw CloudError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw CloudError.invalidResponse }
        let parsed = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .object([:])
        switch http.statusCode {
        case 401, 403: throw CloudError.unauthorized
        case 200..<300: return parsed
        default:
            let code = parsed["rcode"].int.map(String.init) ?? parsed["code"].string ?? parsed["errorCode"].string ?? "unknown"
            throw CloudError.http(status: http.statusCode, code: code)
        }
    }

    /// Ids + revision clocks for a whole table, one page.
    public func list(table: String, limit: Int = pageLimit) async throws -> Listing {
        let limit = max(1, min(limit, Self.pageLimit))
        let body = try await request("GET", path: "/data/v2/\(table)", query: [
            .init(name: "table_ver", value: "1"),
            .init(name: "select", value: "record_id,mod_timestamp"),
            .init(name: "limit", value: String(limit)),
            .init(name: "meta", value: "true"),
            .init(name: "include_deleted_items", value: "false"),
        ])
        let records = (body["records"].array ?? []).compactMap { record -> ListedRecord? in
            guard let id = record["record_id"].string, !id.isEmpty else { return nil }
            return ListedRecord(id: id, modTimestamp: record["mod_timestamp"].int ?? 0)
        }
        return Listing(records: records, hasMore: !body["meta"]["next_offset"].isNull)
    }

    /// Full records for the given ids, fetched in chunks of 100.
    public func get(table: String, ids: [String]) async throws -> [[String: JSONValue]] {
        var all: [[String: JSONValue]] = []
        all.reserveCapacity(ids.count)
        var index = 0
        while index < ids.count {
            let chunk = Array(ids[index..<min(index + Self.getChunk, ids.count)])
            index += Self.getChunk
            let body = try await request("POST", path: "/data/v2/\(table)/get",
                                         query: [.init(name: "table_ver", value: "1"), .init(name: "meta", value: "false")],
                                         body: .object(["records": .array(chunk.map(JSONValue.string))]))
            for record in body["records"].array ?? [] {
                if let object = record.object { all.append(object) }
            }
        }
        return all
    }

    public func getOne(table: String, id: String) async throws -> [String: JSONValue]? {
        try await get(table: table, ids: [id]).first { $0["record_id"]?.string == id }
    }

    /// Upsert with Samsung's optimistic condition: the server keeps the newer mod_timestamp.
    public func upload(table: String, record: [String: JSONValue]) async throws {
        let body = try await request("PUT", path: "/data/v2/\(table)", query: [
            .init(name: "table_ver", value: "1"),
            .init(name: "upsert", value: "true"),
            .init(name: "partial_update", value: "true"),
            .init(name: "condition", value: "mod_timestamp lt mod_timestamp"),
        ], body: .object(["records": .array([.object(record)])]))
        try Self.rejectFailed(body)
    }

    public func delete(table: String, id: String) async throws {
        let body = try await request("POST", path: "/data/v2/\(table)", query: [
            .init(name: "action", value: "delete"),
            .init(name: "table_ver", value: "1"),
            .init(name: "condition", value: "mod_timestamp lt mod_timestamp"),
        ], body: .object(["records": .array([.object([
            "record_id": .string(id), "mod_timestamp": JSONValue(Self.nowMillis()),
        ])])]))
        try Self.rejectFailed(body)
    }

    static func rejectFailed(_ body: JSONValue) throws {
        guard let first = body["failed_records"].array?.first else { return }
        throw CloudError.rejected(code: first["rcode"].int.map(String.init) ?? "unknown")
    }

    public static func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

public extension URLSession {
    /// Ephemeral: no cookie/cache persistence, so nothing lands on disk outside the Keychain.
    static let cloud: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()
}
