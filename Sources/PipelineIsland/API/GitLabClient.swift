import Foundation

/// Errors surfaced to the UI. Never carries the token.
public enum GitLabError: Error, LocalizedError, Sendable, Equatable {
    case noToken
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(status: Int)
    case network(String)
    case decoding(String)
    case graphQL([String])

    public var errorDescription: String? {
        switch self {
        case .noToken:
            return "No GitLab token. Add a read_api personal access token in Settings."
        case .unauthorized:
            return "Token rejected by GitLab. Check that it is valid and has read_api scope."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Rate limited by GitLab. Retrying in \(Int(retryAfter))s."
            }
            return "Rate limited by GitLab. Backing off."
        case .serverError(let status):
            return "GitLab returned HTTP \(status)."
        case .network(let message):
            return "Network error: \(message)"
        case .decoding(let message):
            return "Could not read GitLab's response: \(message)"
        case .graphQL(let messages):
            return "GitLab GraphQL error: \(messages.joined(separator: "; "))"
        }
    }

    /// Transient failures that deserve exponential backoff rather than a hard stop.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .serverError, .network:
            return true
        case .noToken, .unauthorized, .decoding, .graphQL:
            return false
        }
    }
}

/// Talks to GitLab's GraphQL endpoint over URLSession. No `glab`, no subprocess.
public actor GitLabClient {
    /// The validated project-centric query from CLAUDE.md.
    static let pipelinesQuery = """
    query {
      projects(membership: true, first: 30, sort: "latest_activity_desc") {
        nodes {
          fullPath
          group { fullPath }
          namespace { fullPath }
          pipelines(first: 3) {
            nodes {
              iid path status ref source duration startedAt finishedAt
              detailedStatus { text }
              user { username name }
              stages { nodes { name status } }
              jobs { nodes { name status stage { name } } }
            }
          }
        }
      }
    }
    """

    private let endpoint: URL
    private let session: URLSession
    private let tokenProvider: @Sendable () -> String?

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = GitLabDate.parse(raw) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Unrecognized date format: \(raw)")
            )
        }
        return decoder
    }()

    public init(
        endpoint: URL = URL(string: "https://gitlab.com/api/graphql") ?? URL(fileURLWithPath: "/"),
        session: URLSession = .shared,
        tokenProvider: @escaping @Sendable () -> String? = { TokenCache.shared.token() }
    ) {
        self.endpoint = endpoint
        self.session = session
        self.tokenProvider = tokenProvider
    }

    /// Build the GraphQL endpoint for a host string from Settings.
    public static func endpoint(for host: String) -> URL {
        var trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { trimmed = "https://gitlab.com" }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: trimmed + "/api/graphql")
            ?? URL(string: "https://gitlab.com/api/graphql")!
    }

    /// The groups the signed-in user belongs to, for the organization picker.
    static let groupsQuery = """
    query {
      currentUser {
        username
        groups(first: 100) {
          nodes { fullPath name projectsCount }
        }
      }
    }
    """

    /// Fetch every membership project's recent pipelines.
    public func fetchPipelines() async throws -> [Project] {
        let payload: ProjectsPayload = try await perform(query: Self.pipelinesQuery)

        return (payload.projects?.nodes ?? [])
            .map { project in
                let stamped = project.pipelineList.map { pipeline -> Pipeline in
                    var copy = pipeline
                    copy.projectPath = project.fullPath
                    return copy
                }
                return Project(
                    fullPath: project.fullPath,
                    pipelines: Connection(nodes: stamped)
                )
            }
            .filter { !$0.pipelineList.isEmpty }
    }

    /// The user's groups plus their username, for Settings.
    public func fetchGroups() async throws -> (username: String, groups: [GitLabGroup]) {
        let payload: CurrentUserGroupsPayload = try await perform(query: Self.groupsQuery)
        guard let user = payload.currentUser else { throw GitLabError.unauthorized }
        return (user.username, user.groups?.nodes ?? [])
    }

    /// Cheap auth probe for Settings — validates the token without a full poll.
    public func verifyToken() async throws -> String {
        struct CurrentUserPayload: Codable, Sendable {
            struct User: Codable, Sendable { let username: String }
            let currentUser: User?
        }

        let payload: CurrentUserPayload = try await perform(
            query: "query { currentUser { username } }"
        )
        guard let username = payload.currentUser?.username else {
            throw GitLabError.unauthorized
        }
        return username
    }

    // MARK: - Transport

    private func perform<T: Codable & Sendable>(query: String) async throws -> T {
        guard let token = tokenProvider(), !token.isEmpty else {
            throw GitLabError.noToken
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
        } catch {
            throw GitLabError.decoding("Could not encode query: \(error.localizedDescription)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GitLabError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw GitLabError.network("Non-HTTP response.")
        }

        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw GitLabError.unauthorized
        case 429:
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After"))
                .flatMap(TimeInterval.init)
            throw GitLabError.rateLimited(retryAfter: retryAfter)
        case 500...599:
            throw GitLabError.serverError(status: http.statusCode)
        default:
            throw GitLabError.serverError(status: http.statusCode)
        }

        let envelope: GraphQLResponse<T>
        do {
            envelope = try decoder.decode(GraphQLResponse<T>.self, from: data)
        } catch let DecodingError.keyNotFound(key, context) {
            throw GitLabError.decoding("missing \(key.stringValue) at \(Self.path(context))")
        } catch let DecodingError.valueNotFound(_, context) {
            throw GitLabError.decoding("null value at \(Self.path(context))")
        } catch let DecodingError.typeMismatch(_, context) {
            throw GitLabError.decoding("unexpected type at \(Self.path(context))")
        } catch {
            let body = String(decoding: data.prefix(4000), as: UTF8.self)
            let title = body.range(of: "<title>").flatMap { r in
                body[r.upperBound...].split(separator: "<").first.map(String.init)
            }
            let snippet = "[\(http.url?.absoluteString ?? "?")] \(title ?? String(body.prefix(200)))"
            throw GitLabError.decoding("\(error.localizedDescription) Body: \(snippet)")
        }

        // GitLab returns HTTP 200 with an `errors` array for query-level problems.
        if let errors = envelope.errors, !errors.isEmpty {
            let messages = errors.map(\.message)
            if messages.contains(where: {
                $0.localizedCaseInsensitiveContains("authenticate")
                    || $0.localizedCaseInsensitiveContains("unauthorized")
            }) {
                throw GitLabError.unauthorized
            }
            throw GitLabError.graphQL(messages)
        }

        guard let payload = envelope.data else {
            throw GitLabError.decoding("Response contained no data.")
        }
        return payload
    }
}

extension GitLabClient {
    static func path(_ context: DecodingError.Context) -> String {
        context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }
            .joined(separator: ".")
    }
}

// MARK: - Date parsing

/// GitLab timestamps arrive as ISO-8601, sometimes with fractional seconds.
enum GitLabDate {
    static func parse(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()

        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}
