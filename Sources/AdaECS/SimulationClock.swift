import AdaUtils

/// Task-scoped clock override for offline simulation and frame capture.
/// Child schedulers inherit the step; an explicitly supplied scheduler step takes precedence.
public enum SimulationClock {
    @TaskLocal public static var fixedDeltaTime: AdaUtils.TimeInterval?
}
