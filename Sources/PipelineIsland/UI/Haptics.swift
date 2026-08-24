import AppKit
import IOKit

/// Haptic feedback for pipeline state changes.
@MainActor
public enum Haptics {
    /// Master switch, mirrored from `Preferences`.
    public static var isEnabled = true

    /// Whether a first poll has been seen.
    private static var hasBaseline = false

    /// Status of each pipeline as of the last poll, keyed by identity.
    private static var lastStatus: [String: PipelineStatus] = [:]

    private static func tap(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard isEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    /// Called whenever the monitor emits new state.
    public static func pipelinesChanged(_ pipelines: [Pipeline]) {
        var started = false
        var succeeded = false
        var failed = false

        for pipeline in pipelines {
            let identity = pipeline.identity
            let previous = lastStatus[identity]
            lastStatus[identity] = pipeline.status

            guard previous != pipeline.status else { continue }

            if pipeline.isActive, previous == nil {
                started = true
            } else if !pipeline.isActive, let previous, previous.isActive {
                // A real completion: it was running last poll, it is not now.
                if pipeline.status == .failed {
                    failed = true
                } else if pipeline.status == .success {
                    succeeded = true
                }
            }
        }

        let live = Set(pipelines.map(\.identity))
        lastStatus = lastStatus.filter { live.contains($0.key) }

        guard hasBaseline else {
            hasBaseline = true
            return
        }

        // One tap per poll, most significant first.
        if failed {
            // Two beats, distinct from anything else the island does.
            tap(.generic)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                MainActor.assumeIsolated { tap(.generic) }
            }
        } else if succeeded {
            tap(.levelChange)
        } else if started {
            tap(.alignment)
        }
    }

    /// The island expanded under the pointer.
    public static func expanded() {
        tap(.alignment)
    }

    /// Forget history, so switching accounts does not fire a burst of taps.
    public static func resetBaseline() {
        hasBaseline = false
        lastStatus.removeAll()
    }

    /// Whether this Mac has hardware that can actually produce a haptic.
    public static var isSupported: Bool {
        var iterator: io_iterator_t = 0
        let match = IOServiceMatching("AppleActuatorDevice")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }
        let service = IOIteratorNext(iterator)
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }

    // MARK: - Settings previews

    /// Fire one pattern on demand, for the Settings preview buttons.
    public static func demoStart() { tap(.alignment) }
    public static func demoSuccess() { tap(.levelChange) }
    public static func demoFailure() {
        tap(.generic)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            MainActor.assumeIsolated { tap(.generic) }
        }
    }
}
