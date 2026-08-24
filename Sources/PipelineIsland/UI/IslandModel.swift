import Foundation
import SwiftUI

/// What the pill is currently saying. Drives colour, glyph and visibility.
public enum IslandMood: Sendable, Equatable {
    case idle
    case running
    case failed
    case success
    case error

    /// Worst-status-wins ordering: a failure outranks a run, a run outranks a success.
    var rank: Int {
        switch self {
        case .idle: return 0
        case .success: return 1
        case .running: return 2
        case .failed: return 3
        case .error: return 4
        }
    }
}

/// Bridges the `PipelineMonitor` actor to SwiftUI.
@MainActor
@Observable
public final class IslandModel {
    public private(set) var state = MonitorState()
    public var isExpanded = false

    /// Ticks each second so elapsed times count up between polls.
    public private(set) var now = Date()

    /// Drives the enter/exit morph.
    public var isOnScreen = false

    /// True while the island is animating OUT.
    public var isLeaving = false

    /// How long a finished run stays visible, measured from its real `finishedAt`.
    private let finishedLinger: TimeInterval = 30
    /// Failures linger longer than successes — but still expire.
    private let failedLinger: TimeInterval = 600

    private var tickTask: Task<Void, Never>?

    public init() {}

    public func apply(_ newState: MonitorState) {
        state = newState

        updateTicker()
    }

    // MARK: - Derived UI state

    /// Pipelines the island cares about.
    public var relevantPipelines: [Pipeline] {
        let live = state.pipelines.filter { pipeline in
            // Anything actually in flight, always.
            if pipeline.isActive { return true }

            guard let finished = pipeline.finishedAt else { return false }
            let age = now.timeIntervalSince(finished)

            switch pipeline.status {
            case .failed:
                return age < failedLinger
            default:
                return age < finishedLinger
            }
        }
        return live.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            let lhsFailed = lhs.status == .failed
            let rhsFailed = rhs.status == .failed
            if lhsFailed != rhsFailed { return lhsFailed }
            return (lhs.startedAt ?? .distantPast) > (rhs.startedAt ?? .distantPast)
        }
    }

    /// Every pipeline the monitor knows about, newest first.
    public var allPipelines: [Pipeline] {
        state.pipelines.sorted {
            ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast)
        }
    }

    /// Worst status across live pipelines only.
    public var mood: IslandMood {
        if state.error != nil { return .error }
        var worst = IslandMood.idle
        for pipeline in relevantPipelines {
            let mood = Self.mood(for: pipeline.status)
            if mood.rank > worst.rank { worst = mood }
        }
        return worst
    }

    static func mood(for status: PipelineStatus) -> IslandMood {
        if status.isActive { return .running }
        switch status {
        case .failed: return .failed
        case .success: return .success
        default: return .idle
        }
    }

    /// The pipeline the collapsed pill describes — the worst one, newest first.
    public var headline: Pipeline? {
        let worst = mood
        return relevantPipelines.first { Self.mood(for: $0.status) == worst }
            ?? relevantPipelines.first
    }

    /// Everything the headline is *not* describing.
    public var otherPipelines: [Pipeline] {
        guard let headline else { return [] }
        return relevantPipelines.filter { $0.identity != headline.identity }
    }

    /// How many pipelines the collapsed island shows before it stops growing.
    private let collapsedRowLimit = 4

    /// The lines the collapsed island draws — one per live pipeline.
    public var collapsedPipelines: [Pipeline] {
        Array(relevantPipelines.prefix(collapsedRowLimit))
    }

    /// Live pipelines that did not fit in the collapsed island.
    public var hiddenPipelineCount: Int {
        max(relevantPipelines.count - collapsedRowLimit, 0)
    }

    /// Pipelines to draw stage detail for when expanded.
    public var expandedDetail: [Pipeline] {
        Array(relevantPipelines.prefix(6))
    }

    /// Whether the panel should be on screen at all.
    public var isVisible: Bool {
        // Never disappear while the user is reading it.
        if isExpanded { return true }
        if state.error != nil { return true }
        return !relevantPipelines.isEmpty
    }

    /// How far through its linger window the most recent finished run is, 0...1.
    public var settleProgress: Double {
        guard !relevantPipelines.contains(where: \.isActive) else { return 0 }
        guard let finished = relevantPipelines
            .compactMap(\.finishedAt)
            .max() else { return 0 }

        let age = now.timeIntervalSince(finished)
        let window = relevantPipelines.contains { $0.status == .failed }
            ? failedLinger
            : finishedLinger
        let dimStart = window * 0.66
        guard age > dimStart else { return 0 }
        return min((age - dimStart) / (window - dimStart), 1)
    }

    // MARK: - Ticker

    /// Only run a 1s timer when something is actually counting.
    private func updateTicker() {
        let needsTicker = !relevantPipelines.isEmpty
        if needsTicker {
            guard tickTask == nil else { return }
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let self else { return }
                    self.now = Date()
                    if self.relevantPipelines.isEmpty {
                        self.stopTicker()
                        return
                    }
                }
            }
        } else {
            now = Date()
            stopTicker()
        }
    }

    private func stopTicker() {
        tickTask?.cancel()
        tickTask = nil
    }
}

// MARK: - Formatting

enum IslandFormat {
    /// `1:24` style elapsed, or `100s` for short finished runs.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        guard total >= 60 else { return "\(max(total, 0))s" }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Live elapsed time for a running pipeline.
    static func elapsed(_ pipeline: Pipeline, now: Date) -> String? {
        if pipeline.isActive {
            guard let startedAt = pipeline.startedAt else { return nil }
            return duration(now.timeIntervalSince(startedAt))
        }
        guard let seconds = pipeline.duration else { return nil }
        return duration(TimeInterval(seconds))
    }
}
