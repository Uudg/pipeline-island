import SwiftUI

/// Colour + glyph vocabulary shared by the pill and the expanded rows.
enum StatusStyle {
    static func color(for status: PipelineStatus) -> Color {
        if status.isActive { return .blue }
        switch status {
        case .success: return .green
        case .failed: return .red
        case .canceled, .canceling, .skipped: return .secondary
        case .manual, .scheduled: return .orange
        default: return .secondary
        }
    }

    /// SF Symbol for a pipeline/job status.
    static func symbol(for status: PipelineStatus) -> String {
        if status.isActive { return "circle.dotted" }
        switch status {
        case .success: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .canceled, .canceling: return "slash.circle"
        case .skipped: return "arrow.right.circle"
        case .manual: return "hand.tap"
        case .scheduled: return "clock"
        default: return "circle"
        }
    }

    static func color(for mood: IslandMood) -> Color {
        switch mood {
        case .running: return .blue
        case .failed: return .red
        case .success: return .green
        case .error: return .orange
        case .idle: return .secondary
        }
    }
}

/// A spinner that only animates while a pipeline is genuinely active.
struct ActivityGlyph: View {
    var color: Color
    @State private var spinning = false

    var body: some View {
        Image(systemName: "circle.dotted")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(color)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(
                .linear(duration: 2).repeatForever(autoreverses: false),
                value: spinning
            )
            .onAppear { spinning = true }
    }
}

/// One pipeline in the expanded panel: project, ref, elapsed, stage strip.
struct StatusRow: View {
    let pipeline: Pipeline
    let now: Date
    let onOpen: (Pipeline) -> Void

    @State private var isHovering = false

    private var projectName: String {
        pipeline.projectPath.split(separator: "/").last.map(String.init)
            ?? pipeline.projectPath
    }

    var body: some View {
        Button(action: { onOpen(pipeline) }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if pipeline.isActive {
                        ActivityGlyph(color: StatusStyle.color(for: pipeline.status))
                    } else {
                        Image(systemName: StatusStyle.symbol(for: pipeline.status))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(StatusStyle.color(for: pipeline.status))
                    }

                    Text(projectName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let ref = pipeline.ref {
                        Text(ref)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 4)

                    if let elapsed = IslandFormat.elapsed(pipeline, now: now) {
                        Text(elapsed)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                StageStrip(pipeline: pipeline)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.10 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Open pipeline #\(pipeline.iid) in the browser")
    }
}

/// Stage strip: GitLab's pipeline graph, shrunk to fit a pill.
struct StageStrip: View {
    let pipeline: Pipeline
    /// Compact mode drops the labels and draws dots only, for the collapsed pill.
    var compact: Bool = false

    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            ForEach(Array(pipeline.jobsByStage.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Capsule()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: compact ? 4 : 6, height: 1)
                }

                HStack(spacing: 3) {
                    ForEach(group.jobs) { job in
                        JobDot(status: job.status, name: job.name, stage: group.stage.name)
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    }
                    if group.jobs.isEmpty {
                        JobDot(status: group.stage.status, name: group.stage.name, stage: group.stage.name)
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    }
                }
            }

            if !compact, let running = runningLabel {
                Text(running)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 2)
            }
        }
        .frame(height: compact ? 10 : 12)
    }

    private var runningLabel: String? {
        let names = pipeline.runningJobs.map(\.name)
        guard !names.isEmpty else { return nil }
        return names.joined(separator: ", ")
    }
}

/// One job, drawn as a filled dot.
struct JobDot: View {
    let status: PipelineStatus
    let name: String
    let stage: String

    @State private var pulse = false

    private var isRunning: Bool { status == .running }
    /// Not-yet-started work reads as an outline rather than a solid dot.
    private var isPending: Bool { status == .created || status == .pending || status == .manual }

    var body: some View {
        Circle()
            .strokeBorder(
                StatusStyle.color(for: status).opacity(isPending ? 0.65 : 0),
                lineWidth: 1.5
            )
            .background(
                Circle().fill(
                    isPending ? Color.clear : StatusStyle.color(for: status)
                )
            )
            .frame(width: 7, height: 7)
            .scaleEffect(isRunning && pulse ? 1.35 : 1.0)
            .opacity(isRunning && pulse ? 0.55 : 1.0)
            .animation(
                isRunning
                    ? .easeInOut(duration: 0.65).repeatForever(autoreverses: true)
                    : .default,
                value: pulse
            )
            .onAppear { if isRunning { pulse = true } }
            .onChange(of: isRunning) { _, running in pulse = running }
            .help("\(stage) › \(name): \(status.rawValue.lowercased())")
    }
}
