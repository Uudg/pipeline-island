import AppKit
import SwiftUI

/// The island itself: a collapsed pill that expands on hover.
struct IslandView: View {
    @Bindable var model: IslandModel
    /// True when the panel is tucked under a physical notch cutout.
    let hasNotch: Bool
    /// Height of the notch cutout in points, 0 on a notchless display.
    var notchHeight: CGFloat = 0
    /// Notch width, so the resting island is never narrower than the cutout.
    var notchWidth: CGFloat = 0
    let onOpen: (Pipeline) -> Void
    let onQuit: () -> Void
    /// Routed through the controller so the resize is sequenced around the animation.
    var onHoverChange: (Bool) -> Void = { _ in }

    /// True while animating out; selects the gentler exit geometry.
    private var isLeaving: Bool { model.isLeaving }

    var body: some View {
        VStack(spacing: 0) {
            // On a notched Mac the top band of the island sits behind the
            // physical cutout. Reserving it keeps content clear of the camera
            // housing and makes the bezel and the pill read as one object.
            //
            // The band is reserved in FULL in every state. An earlier version
            // shrank it to 40% when expanded to avoid a dead strip, which put
            // the first row of text physically behind the camera housing
            // (reported: "the text is overlayed by the real notch"). The cutout
            // is opaque hardware — nothing may be drawn under it, ever.
            if hasNotch {
                Color.clear.frame(height: notchHeight)
            }

            if isCompactRest {
                restBadge
            } else {
                collapsed
                if model.isExpanded {
                    Divider().opacity(0.35)
                    expanded
                }
            }
        }
        .frame(width: currentWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(background)
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(Color.white.opacity(hasNotch ? 0 : 0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(model.isExpanded ? 0.35 : 0.2),
                radius: model.isExpanded ? 18 : 8, y: 4)
        .scaleEffect(
            x: model.isOnScreen ? 1 : (isLeaving ? 0.97 : 0.86),
            y: model.isOnScreen ? 1 : (isLeaving ? 0.80 : 0.55),
            anchor: .top
        )
        .opacity(model.isOnScreen
                 ? (model.isExpanded ? 1 : 1 - model.settleProgress * 0.55)
                 : 0)
        .blur(radius: model.isOnScreen ? 0 : (isLeaving ? 1.5 : 3))
        // Hover and hit-testing belong to the DRAWN pill, not the canvas.
        //
        // The window is a fixed 620x422 so expansion never resizes it, but the
        // collapsed pill is only ~52pt tall. Attaching `.onHover` to the outer
        // frame made the whole invisible 422pt area a hover target, so the
        // island expanded ~370pt below anything visible — swallowing the mouse
        // on its way to a window underneath. `contentShape` scopes both hover
        // and clicks to the pill's actual silhouette.
        .contentShape(shape)
        .onHover { hovering in
            onHoverChange(hovering)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(true)
        .animation(Motion.content, value: model.state.signature)
        .animation(Motion.expand, value: model.isExpanded)
    }

    /// True when the island should sit at exactly notch width.
    private var isCompactRest: Bool {
        hasNotch && !model.isExpanded
    }

    /// Width of the drawn island for the current state.
    private var currentWidth: CGFloat {
        model.isExpanded
            ? NotchGeometry.Width.expanded
            : NotchGeometry.Width.resting(hasNotch: hasNotch, notchWidth: notchWidth)
    }

    /// Resting badge for a notched Mac.
    private var restBadge: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            if let pipeline = model.headline {
                if pipeline.isActive {
                    ActivityGlyph(color: StatusStyle.color(for: pipeline.status))
                } else {
                    Image(systemName: StatusStyle.symbol(for: pipeline.status))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(StatusStyle.color(for: pipeline.status))
                }
                if model.relevantPipelines.count > 1 {
                    Text("\(model.relevantPipelines.count)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                }
            } else if model.state.error != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 14)
        .padding(.bottom, 3)
        .transition(.opacity)
    }

    /// Content widths.
    private var collapsedWidth: CGFloat { NotchGeometry.Width.collapsed }
    private var expandedWidth: CGFloat { NotchGeometry.Width.expanded }

    // MARK: - Chrome

    /// Square top edge under a cutout, fully rounded otherwise.
    private var shape: some InsettableShape {
        UnevenRoundedRectangle(
            topLeadingRadius: hasNotch ? 0 : 14,
            bottomLeadingRadius: hasNotch ? 18 : 14,
            bottomTrailingRadius: hasNotch ? 18 : 14,
            topTrailingRadius: hasNotch ? 0 : 14,
            style: .continuous
        )
    }

    private var background: some View {
        ZStack {
            Color.black.opacity(hasNotch ? 1.0 : 0.92)
            if !hasNotch {
                VisualEffectBackground()
                    .opacity(0.35)
            }
        }
    }

    // MARK: - Collapsed pill

    /// The collapsed island: **one line per pipeline**, stacked.
    private var collapsed: some View {
        VStack(spacing: 0) {
            if let error = model.state.error {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.orange)
                        .frame(width: 13)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 2)
                }
                .padding(.horizontal, 12)
                .frame(height: 32)

            } else if model.collapsedPipelines.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.25))
                        .frame(width: 13)
                    Text("no pipelines running")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer(minLength: 2)
                }
                .padding(.horizontal, 12)
                .frame(height: 32)

            } else {
                ForEach(Array(model.collapsedPipelines.enumerated()), id: \.element.id) { index, pipeline in
                    if index > 0 {
                        Divider()
                            .opacity(0.14)
                            .padding(.horizontal, 10)
                    }
                    PipelineLine(
                        pipeline: pipeline,
                        now: model.now,
                        onOpen: onOpen
                    )
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
                }

                // Overflow, when more pipelines are live than the pill will show.
                if model.hiddenPipelineCount > 0 {
                    HStack {
                        Spacer()
                        Text("+\(model.hiddenPipelineCount) more — hover to see all")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.4))
                        Spacer()
                    }
                    .frame(height: 18)
                }
            }
        }
    }

    private var glyph: some View {
        Group {
            switch model.mood {
            case .running:
                ActivityGlyph(color: .blue)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .success:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .idle:
                Image(systemName: "circle.fill").foregroundStyle(.white.opacity(0.25))
            }
        }
        .font(.system(size: 11, weight: .bold))
        .frame(width: 13)
    }

    private func shortName(_ pipeline: Pipeline) -> String {
        pipeline.projectPath.split(separator: "/").last.map(String.init)
            ?? pipeline.projectPath
    }

    // MARK: - Expanded panel

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.expandedDetail) { pipeline in
                StageDetail(pipeline: pipeline)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
            }

            if model.expandedDetail.isEmpty {
                Text(model.state.error ?? "Nothing running right now.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .transition(.opacity)
            }

            Divider().opacity(0.25).padding(.vertical, 2)

            HStack(spacing: 6) {
                if let lastUpdate = model.state.lastUpdate {
                    Text("updated \(IslandFormat.duration(model.now.timeIntervalSince(lastUpdate))) ago")
                } else {
                    Text("connecting…")
                }
                Spacer()
                Button("Quit", action: onQuit)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .padding(.top, 4)
        .clipped()
        .transition(
            .asymmetric(
                insertion: .opacity.animation(Motion.expand.delay(0.06)),
                removal: .opacity.animation(.easeOut(duration: 0.12))
            )
        )
    }
}

/// Per-pipeline stage detail, shown only when the island is expanded.
struct StageDetail: View {
    let pipeline: Pipeline

    private var projectName: String {
        pipeline.projectPath.split(separator: "/").last.map(String.init)
            ?? pipeline.projectPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(projectName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("#\(pipeline.iid)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }

            ForEach(Array(pipeline.jobsByStage.enumerated()), id: \.offset) { _, group in
                HStack(alignment: .center, spacing: 7) {
                    Text(group.stage.name)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(StatusStyle.color(for: group.stage.status))
                        .frame(width: 52, alignment: .leading)

                    FlowLayout(spacing: 10, lineSpacing: 3) {
                        ForEach(group.jobs) { job in
                            HStack(spacing: 4) {
                                JobDot(status: job.status, name: job.name, stage: group.stage.name)
                                Text(Self.shortJobName(job.name, stage: group.stage.name))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(job.status == .running ? .primary : .secondary)
                                    .lineLimit(1)
                            }
                        }
                        if group.jobs.isEmpty {
                            Text("—")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    /// Strip a redundant `stage:` prefix from a job name.
    static func shortJobName(_ name: String, stage: String) -> String {
        let prefix = stage + ":"
        guard name.hasPrefix(prefix), name.count > prefix.count else { return name }
        return String(name.dropFirst(prefix.count))
    }
}

/// A minimal flow layout: lay children out left to right, wrap when full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// One pipeline as a single compact line, for the collapsed island.
struct PipelineLine: View {
    let pipeline: Pipeline
    let now: Date
    let onOpen: (Pipeline) -> Void

    @State private var isHovering = false

    private var projectName: String {
        pipeline.projectPath.split(separator: "/").last.map(String.init)
            ?? pipeline.projectPath
    }

    var body: some View {
        HStack(spacing: 7) {
            if pipeline.isActive {
                ActivityGlyph(color: StatusStyle.color(for: pipeline.status))
                    .frame(width: 13)
            } else {
                Image(systemName: StatusStyle.symbol(for: pipeline.status))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(StatusStyle.color(for: pipeline.status))
                    .frame(width: 13)
            }

            Text(projectName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .layoutPriority(2)

            Text("#\(pipeline.iid)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))

            if let ref = pipeline.ref {
                Text(ref)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
            }

            StageStrip(pipeline: pipeline, compact: true)

            if let job = pipeline.runningJobs.first {
                Text(job.name)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            if pipeline.isActive {
                Text(IslandFormat.elapsed(pipeline, now: now) ?? "—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .monospacedDigit()
                    .help("Running for this long")
            } else if let seconds = pipeline.duration {
                HStack(spacing: 3) {
                    Image(systemName: "timer")
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.35))
                    Text(IslandFormat.duration(TimeInterval(seconds)))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .monospacedDigit()
                }
                .help("Took \(IslandFormat.duration(TimeInterval(seconds))) to run")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(isHovering ? 0.07 : 0))
                .padding(.horizontal, 5)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { onOpen(pipeline) }
        .help("Open \(pipeline.projectPath) #\(pipeline.iid) in the browser")
    }
}

/// `NSVisualEffectView` bridge: `.ultraThinMaterial` misreads inside a borderless panel.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
