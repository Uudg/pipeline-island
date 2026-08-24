import Foundation

/// A snapshot of everything the UI needs to draw one frame.
public struct MonitorState: Sendable, Equatable {
    public var projects: [Project]
    public var lastUpdate: Date?
    public var error: String?
    public var isPolling: Bool

    public init(
        projects: [Project] = [],
        lastUpdate: Date? = nil,
        error: String? = nil,
        isPolling: Bool = false
    ) {
        self.projects = projects
        self.lastUpdate = lastUpdate
        self.error = error
        self.isPolling = isPolling
    }

    /// Every pipeline across every project, newest activity first.
    public var pipelines: [Pipeline] {
        projects.flatMap(\.pipelineList)
    }

    public var activePipelines: [Pipeline] {
        pipelines.filter(\.isActive)
    }

    public var failedPipelines: [Pipeline] {
        pipelines.filter { $0.status == .failed }
    }

    public var hasActivePipeline: Bool {
        pipelines.contains(where: \.isActive)
    }

    /// Combined change signature. The monitor only emits when this differs.
    public var signature: String {
        let body = pipelines
            .map(\.signature)
            .sorted()
            .joined(separator: ";")
        return "\(body)|err:\(error ?? "")"
    }
}

/// Adaptive polling engine.
public actor PipelineMonitor {
    public struct Cadence: Sendable {
        public var active: TimeInterval = 5
        /// Idle cadence.
        public var idle: TimeInterval = 10
        public var suspended: TimeInterval = 60
        public var backoffBase: TimeInterval = 5
        public var backoffCeiling: TimeInterval = 300

        public init() {}
    }

    private let client: GitLabClient
    private var cadence: Cadence

    private var state = MonitorState()
    private var lastSignature: String?
    private var pollTask: Task<Void, Never>?

    /// Consecutive retryable failures; drives the exponential backoff.
    private var failureCount = 0
    /// When true, poll at the suspended interval (screen asleep / app unfocused).
    private var isSuspended = false

    private var continuations: [UUID: AsyncStream<MonitorState>.Continuation] = [:]

    /// Which projects the island reports on.
    private var scope: PipelineScope = .all
    /// Groups selected when `scope == .groups`.
    private var selectedGroups: Set<String> = []
    /// Whose runs to show, independent of which projects are watched.
    private var authorScope: PipelineAuthorScope = .everyone
    /// The signed-in user's namespace, needed to resolve `.mine`.
    private var username: String?

    public init(client: GitLabClient = GitLabClient(), cadence: Cadence = Cadence()) {
        self.client = client
        self.cadence = cadence
    }

    deinit {
        pollTask?.cancel()
        for continuation in continuations.values {
            continuation.finish()
        }
    }

    // MARK: - Observation

    /// A stream of state changes.
    public func stateStream() -> AsyncStream<MonitorState> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(state)

            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    public func currentState() -> MonitorState { state }

    // MARK: - Control

    public func start() {
        guard pollTask == nil else { return }
        state.isPolling = true

        pollTask = Task.detached { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        state.isPolling = false
        emitIfChanged(force: true)
    }

    /// Screen asleep or app unfocused — slow down without tearing the loop down.
    public func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
    }

    /// Configure which projects are watched.
    public func setScope(
        _ scope: PipelineScope,
        groups: Set<String>,
        author: PipelineAuthorScope = .everyone,
        username: String?
    ) {
        self.scope = scope
        self.selectedGroups = groups
        self.authorScope = author
        if let username { self.username = username }
        state.projects = filtered(unfilteredProjects)
        emitIfChanged()
    }

    /// Force an out-of-band poll, e.g. after the user saves a new token.
    public func refreshNow() async {
        await pollOnce()
    }

    // MARK: - Loop

    private func runLoop() async {
        while !Task.isCancelled {
            await pollOnce()

            let delay = nextInterval()
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return // cancelled
            }
        }
    }

    private func pollOnce() async {
        do {
            let projects = try await client.fetchPipelines()
            failureCount = 0
            unfilteredProjects = projects
            state.projects = filtered(projects)
            state.lastUpdate = Date()
            state.error = nil
        } catch let error as GitLabError {
            if error.isRetryable {
                failureCount += 1
            } else {
                // Hard failure (bad token, bad query): stop hammering the API.
                failureCount = 0
            }
            state.error = error.errorDescription
        } catch {
            failureCount += 1
            state.error = error.localizedDescription
        }
        emitIfChanged()
    }

    /// Poll cadence for the next tick.
    private func nextInterval() -> TimeInterval {
        if failureCount > 0 {
            // 5, 10, 20, 40 ... capped at 5 minutes.
            let factor = pow(2.0, Double(failureCount - 1))
            return min(cadence.backoffBase * factor, cadence.backoffCeiling)
        }
        if isSuspended { return cadence.suspended }
        return state.hasActivePipeline ? cadence.active : cadence.idle
    }

    /// Last unfiltered result, so a scope change can be applied without waiting for the next poll.
    private var unfilteredProjects: [Project] = []

    private func filtered(_ projects: [Project]) -> [Project] {
        var result = projects

        switch scope {
        case .all:
            break
        case .mine:
            if let username {
                result = result.filter { $0.isPersonal(of: username) }
            } else {
                result = result.filter { $0.groupPath == nil }
            }
        case .groups:
            result = result.filter { project in
                guard let group = project.groupPath else { return false }
                return selectedGroups.contains { group == $0 || group.hasPrefix($0 + "/") }
            }
        }

        if authorScope == .me, let username {
            result = result.compactMap { project in
                let mine = project.pipelineList.filter { $0.wasTriggered(by: username) }
                guard !mine.isEmpty else { return nil }
                return Project(
                    fullPath: project.fullPath,
                    pipelines: Connection(nodes: mine),
                    group: project.group,
                    namespace: project.namespace
                )
            }
        }
        return result
    }

    /// Dedupe gate: observers only wake when the signature actually moved.
    private func emitIfChanged(force: Bool = false) {
        let signature = state.signature
        guard force || signature != lastSignature else { return }
        lastSignature = signature

        let snapshot = state
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }
}
