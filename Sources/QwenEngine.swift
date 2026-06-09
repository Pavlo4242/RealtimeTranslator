import Foundation
import FluidAudio
import Observation

// MARK: - State

enum QwenEngineState: Equatable {
    case idle
    case loading
    case ready
    case inferring
    case failed(String)

    static func == (l: Self, r: Self) -> Bool {
        switch (l, r) {
        case (.idle, .idle), (.loading, .loading),
             (.ready, .ready), (.inferring, .inferring): return true
        case let (.failed(a), .failed(b)): return a == b
        default: return false
        }
    }
}

// MARK: - Engine

/// Wraps FluidAudio's Qwen3AsrManager (0.6B, INT8 ~0.6 GB on first run).
/// Thai audio → Thai text. Translation to English is handled separately.
@Observable
@MainActor
final class QwenEngine {

    var state: QwenEngineState = .idle
    var isReady: Bool { state == .ready }

    private var manager: Qwen3AsrManager?

    // MARK: - Setup

    func setup() async {
        switch state {
        case .idle, .failed: break
        default: return
        }
        state = .loading
        do {
            // Qwen3AsrManager handles model download/load internally via variant parameter
            manager = try await Qwen3AsrManager(variant: .int8)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Transcription

    /// Accepts 16 kHz mono Float32 PCM. Returns Thai text.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let mgr = manager else { throw QwenError.notReady }
        state = .inferring
        defer { if state == .inferring { state = .ready } }

        let thai = try await mgr.transcribe(
            audioSamples: samples,
            language: "th",       // pinned; pass nil for auto-detect
            maxNewTokens: 256     // enough for a short chunk sentence
        )
        return thai.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum QwenError: LocalizedError {
    case notReady
    var errorDescription: String? { "Qwen3-ASR model is not loaded." }
}
