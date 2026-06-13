import Foundation

public extension DiagnosisEngine {
    /// The v1 detector set (plan D3): the flagship runaway-daemon catcher, the
    /// R1 hard disk-critical, and the memory-pressure-LEVEL verdict.
    ///
    /// NOT wired into the app here — Phase 4 constructs the engine with this
    /// set (plus the verdict/UI/notification wiring). Exposed as a factory so
    /// both the app and integration tests build the same canonical list.
    static func v1Detectors() -> [Detector] {
        [
            RunawayDaemonDetector(),
            DiskHardCriticalDetector(),
            MemoryPressureVerdictDetector(),
        ]
    }
}
