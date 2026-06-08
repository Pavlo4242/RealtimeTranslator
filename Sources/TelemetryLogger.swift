import Foundation
import os

/// Lightweight per-event wall-clock timer.
/// Each instance is created and used within a single @MainActor process() call,
/// so no locking is required.
@MainActor
final class TelemetryLogger {

    private let log = Logger(subsystem: "com.realtimetranslator", category: "telemetry")
    private var starts: [String: Date] = [:]

    func start(_ event: String) {
        starts[event] = Date()
    }

    func end(_ event: String, engine: String) {
        guard let t = starts.removeValue(forKey: event) else { return }
        let ms = Int(Date().timeIntervalSince(t) * 1000)
        log.info("[\(engine, privacy: .public)] \(event, privacy: .public): \(ms, privacy: .public)ms")
    }
}