import Foundation

// MARK: - Status

/// Pipeline / stage / job status as returned by the GitLab GraphQL API.
public enum PipelineStatus: String, Codable, Sendable, CaseIterable {
    case created = "CREATED"
    case waitingForResource = "WAITING_FOR_RESOURCE"
    case preparing = "PREPARING"
    case pending = "PENDING"
    case running = "RUNNING"
    case success = "SUCCESS"
    case failed = "FAILED"
    case canceling = "CANCELING"
    case canceled = "CANCELED"
    case skipped = "SKIPPED"
    case manual = "MANUAL"
    case scheduled = "SCHEDULED"
    case unknown = "UNKNOWN"

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PipelineStatus(rawValue: raw.uppercased()) ?? .unknown
    }

    /// Active means "this pipeline is going somewhere" — poll fast.
    public var isActive: Bool {
        switch self {
        case .created, .pending, .running, .waitingForResource, .preparing:
            return true
        case .success, .failed, .canceling, .canceled, .skipped, .manual,
             .scheduled, .unknown:
            return false
        }
    }

    /// A finished pipeline that will not change again.
    public var isTerminal: Bool {
        switch self {
        case .success, .failed, .canceled, .skipped:
            return true
        default:
            return false
        }
    }
}

// MARK: - Domain models

public struct Job: Codable, Sendable, Hashable, Identifiable {
    public struct StageRef: Codable, Sendable, Hashable {
        public let name: String
    }

    public let name: String
    public let status: PipelineStatus
    public let stage: StageRef?

    public var id: String { "\(stage?.name ?? "")/\(name)" }
    public var stageName: String? { stage?.name }
}

public struct Stage: Codable, Sendable, Hashable, Identifiable {
    public let name: String
    public let status: PipelineStatus

    public var id: String { name }
}

public struct Pipeline: Codable, Sendable, Hashable, Identifiable {
    public struct DetailedStatus: Codable, Sendable, Hashable {
        public let text: String?
    }

    /// GitLab returns `iid` as a string in GraphQL — keep it a string.
    public let iid: String
    /// Server-supplied path, e.g. `/acme/web-app/-/pipelines/2783269154`.
    ///
    /// Load-bearing: GitLab's pipeline URLs use the pipeline's **global id**, not
    /// its `iid`. Building a URL from `iid` yields a 404 (measured: iid 438 vs id
    /// 2783269154). Always prefer this value; the `iid` fallback in `webURL()`
    /// exists only for fixtures that predate this field.
    public let path: String?
    public let status: PipelineStatus
    public let ref: String?
    public let source: String?
    public let duration: Int?
    public let startedAt: Date?
    public let finishedAt: Date?
    public let detailedStatus: DetailedStatus?
    public let stages: Connection<Stage>?
    public let jobs: Connection<Job>?
    /// Who triggered this run. Nil for schedules and some system triggers.
    public let user: UserRef?

    public init(
        iid: String,
        path: String? = nil,
        status: PipelineStatus,
        ref: String? = nil,
        source: String? = nil,
        duration: Int? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        detailedStatus: DetailedStatus? = nil,
        stages: Connection<Stage>? = nil,
        jobs: Connection<Job>? = nil,
        user: UserRef? = nil,
        projectPath: String = ""
    ) {
        self.iid = iid
        self.path = path
        self.status = status
        self.ref = ref
        self.source = source
        self.duration = duration
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.detailedStatus = detailedStatus
        self.stages = stages
        self.jobs = jobs
        self.user = user
        self.projectPath = projectPath
    }

    /// Stamped by `GitLabClient` after decoding: GraphQL nests pipelines under the project.
    public var projectPath: String = ""

    public var id: String { "\(projectPath)#\(iid)" }

    private enum CodingKeys: String, CodingKey {
        case iid, path, status, ref, source, duration, startedAt, finishedAt
        case detailedStatus, stages, jobs, user
    }

    /// True when this run was triggered by `username`.
    public func wasTriggered(by username: String) -> Bool {
        user?.username == username
    }

    public var stageList: [Stage] { stages?.nodes ?? [] }
    public var jobList: [Job] { jobs?.nodes ?? [] }
    public var isActive: Bool { status.isActive }
    public var runningJobs: [Job] { jobList.filter { $0.status == .running } }
    public var failedJobs: [Job] { jobList.filter { $0.status == .failed } }

    /// Stable identity for one pipeline run.
    public var identity: String { "\(projectPath)#\(iid)" }

    /// Jobs grouped by stage, in the pipeline's own stage order.
    public var jobsByStage: [(stage: Stage, jobs: [Job])] {
        let grouped = Dictionary(grouping: jobList) { $0.stageName ?? "" }
        var result = stageList.map { stage in
            (stage: stage, jobs: grouped[stage.name] ?? [])
        }
        // Any job referencing a stage the stages list didn't include.
        let known = Set(stageList.map(\.name))
        for (name, jobs) in grouped where !name.isEmpty && !known.contains(name) {
            result.append((stage: Stage(name: name, status: jobs.first?.status ?? .created), jobs: jobs))
        }
        return result
    }

    /// Seconds since the pipeline started, for live elapsed display while `duration` is still nil.
    public var elapsed: TimeInterval? {
        if let duration { return TimeInterval(duration) }
        guard let startedAt else { return nil }
        return Date().timeIntervalSince(startedAt)
    }

    /// Web URL for click-through.
    ///
    /// Uses the server-supplied `path` whenever present. The `iid`-based fallback
    /// is **wrong for gitlab.com** — pipeline URLs key off the global id — and is
    /// kept only so fixtures without a `path` still produce something.
    public func webURL(host: String = "https://gitlab.com") -> URL? {
        if let path, !path.isEmpty {
            return URL(string: host + path)
        }
        guard !projectPath.isEmpty else { return nil }
        return URL(string: "\(host)/\(projectPath)/-/pipelines/\(iid)")
    }

    /// Change signature for dedupe: `iid|status|stages|runningJobs`.
    public var signature: String {
        let stagePart = stageList
            .map { "\($0.name):\($0.status.rawValue)" }
            .joined(separator: ",")
        let runningPart = runningJobs
            .map(\.name)
            .sorted()
            .joined(separator: ",")
        return "\(projectPath)#\(iid)|\(status.rawValue)|\(stagePart)|\(runningPart)"
    }
}

/// The user who triggered a pipeline.
public struct UserRef: Codable, Sendable, Hashable {
    public let username: String
    public let name: String?

    public init(username: String, name: String? = nil) {
        self.username = username
        self.name = name
    }
}

public struct Project: Codable, Sendable, Hashable, Identifiable {
    /// Owning group, or nil for a project in a personal namespace.
    public struct GroupRef: Codable, Sendable, Hashable {
        public let fullPath: String
        public init(fullPath: String) { self.fullPath = fullPath }
    }
    /// Owning namespace — a group path OR a user's personal namespace.
    public struct NamespaceRef: Codable, Sendable, Hashable {
        public let fullPath: String
        public init(fullPath: String) { self.fullPath = fullPath }
    }

    public let fullPath: String
    public let pipelines: Connection<Pipeline>?
    public let group: GroupRef?
    public let namespace: NamespaceRef?

    public init(
        fullPath: String,
        pipelines: Connection<Pipeline>?,
        group: GroupRef? = nil,
        namespace: NamespaceRef? = nil
    ) {
        self.fullPath = fullPath
        self.pipelines = pipelines
        self.group = group
        self.namespace = namespace
    }

    public var id: String { fullPath }
    public var pipelineList: [Pipeline] { pipelines?.nodes ?? [] }

    /// Group path when the project belongs to a group, else nil.
    public var groupPath: String? { group?.fullPath }

    /// True when this project lives in `username`'s personal namespace.
    public func isPersonal(of username: String) -> Bool {
        group == nil && namespace?.fullPath == username
    }

    /// Last path component — what the island pill shows.
    public var shortName: String {
        fullPath.split(separator: "/").last.map(String.init) ?? fullPath
    }
}

// MARK: - GraphQL envelope

/// Generic `{ nodes: [...] }` wrapper used everywhere in GitLab's GraphQL schema.
public struct Connection<T: Codable & Sendable>: Codable, Sendable {
    public let nodes: [T]

    public init(nodes: [T]) {
        self.nodes = nodes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `nodes` can come back null on permission-limited connections.
        self.nodes = try container.decodeIfPresent([T].self, forKey: .nodes) ?? []
    }

    private enum CodingKeys: String, CodingKey { case nodes }
}

extension Connection: Hashable where T: Hashable {}
extension Connection: Equatable where T: Equatable {}

/// Top-level GraphQL response: `{ "data": ..., "errors": [...] }`.
public struct GraphQLResponse<T: Codable & Sendable>: Codable, Sendable {
    public struct GraphQLError: Codable, Sendable {
        public let message: String
    }

    public let data: T?
    public let errors: [GraphQLError]?
}

/// The `data` payload of the project-centric pipeline query.
public struct ProjectsPayload: Codable, Sendable {
    public let projects: Connection<Project>?
}

/// Payload for the groups query used by Settings.
public struct CurrentUserGroupsPayload: Codable, Sendable {
    public struct User: Codable, Sendable {
        public let username: String
        public let groups: Connection<GitLabGroup>?
    }
    public let currentUser: User?
}
