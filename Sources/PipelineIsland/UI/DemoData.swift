import Foundation
import SwiftUI

/// A fake pipeline that runs its whole lifecycle locally.
@MainActor
public enum DemoData {
    /// One frame of the scripted run.
    struct Frame {
        let at: TimeInterval
        let pipelineStatus: PipelineStatus
        /// stage name -> status
        let stages: [(String, PipelineStatus)]
        /// job name -> (stage, status)
        let jobs: [(String, String, PipelineStatus)]
    }

    /// A compressed but faithful staging run.
    static let script: [Frame] = [
        Frame(at: 0, pipelineStatus: .created,
              stages: [("test", .created), ("deploy", .created)],
              jobs: [("test:api", "test", .created), ("test:payments", "test", .created),
                     ("test:docker-build", "test", .created), ("deploy:staging", "deploy", .created)]),

        Frame(at: 2, pipelineStatus: .running,
              stages: [("test", .running), ("deploy", .created)],
              jobs: [("test:api", "test", .running), ("test:payments", "test", .running),
                     ("test:docker-build", "test", .running), ("deploy:staging", "deploy", .created)]),

        Frame(at: 7, pipelineStatus: .running,
              stages: [("test", .running), ("deploy", .created)],
              jobs: [("test:api", "test", .success), ("test:payments", "test", .running),
                     ("test:docker-build", "test", .running), ("deploy:staging", "deploy", .created)]),

        Frame(at: 11, pipelineStatus: .running,
              stages: [("test", .running), ("deploy", .created)],
              jobs: [("test:api", "test", .success), ("test:payments", "test", .success),
                     ("test:docker-build", "test", .running), ("deploy:staging", "deploy", .created)]),

        Frame(at: 15, pipelineStatus: .running,
              stages: [("test", .success), ("deploy", .pending)],
              jobs: [("test:api", "test", .success), ("test:payments", "test", .success),
                     ("test:docker-build", "test", .success), ("deploy:staging", "deploy", .pending)]),

        Frame(at: 17, pipelineStatus: .running,
              stages: [("test", .success), ("deploy", .running)],
              jobs: [("test:api", "test", .success), ("test:payments", "test", .success),
                     ("test:docker-build", "test", .success), ("deploy:staging", "deploy", .running)]),

        Frame(at: 24, pipelineStatus: .success,
              stages: [("test", .success), ("deploy", .success)],
              jobs: [("test:api", "test", .success), ("test:payments", "test", .success),
                     ("test:docker-build", "test", .success), ("deploy:staging", "deploy", .success)]),
    ]

    /// A second, failing run so the red path gets exercised too.
    static let failScript: [Frame] = [
        Frame(at: 0, pipelineStatus: .running,
              stages: [("lint", .running), ("test", .created)],
              jobs: [("lint:eslint", "lint", .running), ("test:unit", "test", .created)]),

        Frame(at: 5, pipelineStatus: .running,
              stages: [("lint", .running), ("test", .created)],
              jobs: [("lint:eslint", "lint", .running), ("test:unit", "test", .created)]),

        Frame(at: 9, pipelineStatus: .failed,
              stages: [("lint", .failed), ("test", .skipped)],
              jobs: [("lint:eslint", "lint", .failed), ("test:unit", "test", .skipped)]),
    ]

    /// Build a `MonitorState` for a given script frame.
    static func state(
        frame: Frame,
        project: String,
        iid: String,
        ref: String,
        startedAt: Date
    ) -> MonitorState {
        MonitorState(
            projects: [pipelineProject(frame: frame, project: project, iid: iid,
                                       ref: ref, startedAt: startedAt)],
            lastUpdate: Date(), error: nil, isPolling: true
        )
    }

    private static func pipelineProject(
        frame: Frame,
        project: String,
        iid: String,
        ref: String,
        startedAt: Date
    ) -> Project {
        let pipeline = Pipeline(
            iid: iid,
            path: "/\(project)/-/pipelines/999999\(iid)",
            status: frame.pipelineStatus,
            ref: ref,
            source: "push",
            duration: frame.pipelineStatus.isActive ? nil : Int(frame.at),
            startedAt: startedAt,
            finishedAt: frame.pipelineStatus.isActive ? nil : Date(),
            detailedStatus: .init(text: frame.pipelineStatus.rawValue.lowercased()),
            stages: Connection(nodes: frame.stages.map { Stage(name: $0.0, status: $0.1) }),
            jobs: Connection(nodes: frame.jobs.map {
                Job(name: $0.0, status: $0.2, stage: .init(name: $0.1))
            }),
            projectPath: project
        )
        return Project(fullPath: project, pipelines: Connection(nodes: [pipeline]))
    }

    /// A third cycle: three pipelines running at once, at different points in their lifecycles.
    static func concurrentState(tick: Int, withFailure: Bool = false) -> MonitorState {
        let now = Date()
        let specs: [(project: String, ref: String, iid: String, offset: Int)] = [
            ("acme/web-app", "staging", "442", 0),
            ("acme/dashboard", "main", "88", 2),
            ("acme/notifier", "fix/webhook-retry", "13", 4),
        ]
        let projects = specs.enumerated().map { index, spec -> Project in
            if withFailure && index == 2 {
                return pipelineProject(
                    frame: failScript[2],
                    project: spec.project,
                    iid: spec.iid,
                    ref: spec.ref,
                    startedAt: now.addingTimeInterval(-9)
                )
            }
            let frameIndex = min((tick + spec.offset) % (script.count + 2), script.count - 1)
            return pipelineProject(
                frame: script[frameIndex],
                project: spec.project,
                iid: spec.iid,
                ref: spec.ref,
                startedAt: now.addingTimeInterval(-Double(script[frameIndex].at))
            )
        }
        return MonitorState(projects: projects, lastUpdate: now, error: nil, isPolling: true)
    }

    /// Recording script for a notched Mac.
    ///
    /// The notchless script opens with several seconds of collapsed pill, which
    /// reads fine as a pill but is just a black rectangle on a bezel. Here the
    /// island expands almost immediately and stays open, because the point of
    /// the notch recording is the notch *growing into* a panel.
    static func runForNotchRecording(model: IslandModel) -> Task<Void, Never> {
        Task { @MainActor in
            let start = Date()
            func at(_ seconds: TimeInterval) async {
                let wait = start.addingTimeInterval(seconds).timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            }

            model.apply(MonitorState(projects: [], lastUpdate: Date(), error: nil, isPolling: true))

            let project = "acme/web-app"
            let ref = "staging"

            // Arrive as a bare notch, so the transition is visible.
            await at(1.2)
            model.apply(state(frame: script[0], project: project, iid: "442", ref: ref,
                              startedAt: start.addingTimeInterval(-4)))

            // Expand out of the cutout — the money shot.
            await at(2.8)
            withAnimation(Motion.expand) { model.isExpanded = true }

            // Run the stages while open, so progress is legible.
            for (index, frame) in script.enumerated().dropFirst() {
                await at(3.6 + Double(index) * 1.7)
                model.apply(state(frame: frame, project: project, iid: "442", ref: ref,
                                  startedAt: start.addingTimeInterval(-4)))
            }

            // Collapse back into the notch.
            await at(11.5)
            withAnimation(Motion.collapse) { model.isExpanded = false }

            // A failure arrives and expands on its own.
            await at(13.5)
            model.apply(state(frame: failScript[failScript.count - 1], project: "acme/notifier",
                              iid: "13", ref: "fix/webhook-retry",
                              startedAt: start.addingTimeInterval(-40)))
            await at(14.8)
            withAnimation(Motion.expand) { model.isExpanded = true }
        }
    }

    /// A condensed script for the README recording.
    ///
    /// The normal demo loop runs ~65s, which is far too long for a GIF. This
    /// hits the four things worth showing — arrive, run, expand on hover,
    /// finish, then a failure — in about 20 seconds.
    static func runForRecording(model: IslandModel) -> Task<Void, Never> {
        Task { @MainActor in
            let start = Date()
            func at(_ seconds: TimeInterval) async {
                let target = start.addingTimeInterval(seconds)
                let wait = target.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            }

            // Empty for a beat, so the island is seen arriving.
            model.apply(MonitorState(projects: [], lastUpdate: Date(), error: nil, isPolling: true))

            let ref = "staging"
            let project = "acme/web-app"

            // Arrive, and run through the stages.
            for (index, frame) in script.enumerated() {
                await at(1.5 + Double(index) * 1.6)
                model.apply(state(frame: frame, project: project, iid: "442", ref: ref,
                                  startedAt: start.addingTimeInterval(-8)))
            }

            // Hover: expand and hold long enough to read.
            await at(8.5)
            withAnimation(Motion.expand) { model.isExpanded = true }
            await at(13.0)
            withAnimation(Motion.collapse) { model.isExpanded = false }

            // Success, then let it settle out.
            await at(14.0)
            model.apply(state(frame: script[script.count - 1], project: project, iid: "442",
                              ref: ref, startedAt: start.addingTimeInterval(-100)))

            // A failure, because that is the state people actually care about.
            await at(16.5)
            model.apply(state(frame: failScript[failScript.count - 1], project: "acme/notifier",
                              iid: "13", ref: "fix/webhook-retry",
                              startedAt: start.addingTimeInterval(-40)))
            await at(18.0)
            withAnimation(Motion.expand) { model.isExpanded = true }
        }
    }

    /// Run the demo loop, pushing state into the model on the main actor.
    public static func run(model: IslandModel) -> Task<Void, Never> {
        Task { @MainActor in
            var cycle = 0
            while !Task.isCancelled {
                switch cycle % 3 {
                case 0, 1:
                    let failing = cycle % 3 == 1
                    let frames = failing ? failScript : script
                    let project = failing ? "acme/dashboard" : "acme/web-app"
                    let ref = failing ? "feature/checkout" : "staging"
                    let iid = failing ? "77" : "442"
                    let startedAt = Date()

                    var previous: TimeInterval = 0
                    for frame in frames {
                        let wait = frame.at - previous
                        previous = frame.at
                        if wait > 0 {
                            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                        }
                        if Task.isCancelled { return }
                        model.apply(state(frame: frame, project: project,
                                          iid: iid, ref: ref, startedAt: startedAt))
                    }

                default:
                    // Three at once, each at a different point in its lifecycle.
                    for tick in 0..<10 {
                        if Task.isCancelled { return }
                        model.apply(concurrentState(tick: tick))
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                    }
                }

                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if Task.isCancelled { return }
                model.apply(MonitorState(projects: [], lastUpdate: Date(),
                                         error: nil, isPolling: true))
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                cycle += 1
            }
        }
    }
}
