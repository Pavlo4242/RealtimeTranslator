import Foundation
@preconcurrency import WhisperKit
import Observation

// MARK: - State

enum WhisperEngineState: Equatable {
    case idle
    case loading          // downloading + compiling CoreML model
    case ready
    case inferring
    case failed(String)

    static func == (l: Self, r: Self) -> Bool {
        switch (l, r) {
        case (.idle, .idle), (.loading, .loading),
             (.ready, .ready), (.inferring, .inferring): return true
        case let (.failed(a), .failed(b)):               return a == b
        default:                                          return false
        }
    }
}

// MARK: - Engine

/// Wraps WhisperKit (whisper.cpp + CoreML/ANE).
/// Thai audio → English text in one acoustic pass (translate = true).
@Observable
@MainActor
final class WhisperEngine {

    var state: WhisperEngineState = .idle
    var isReady: Bool { state == .ready }

    // "small" gives a good quality/speed tradeoff for Thai on A-series chips.
    // Swap for "openai_whisper-base" if startup latency matters more than accuracy.
    private let modelName = "openai_whisper-small"
    private var kit: WhisperKit?

    private var decodeOptions: DecodingOptions {
        DecodingOptions(
            verbose:                 false,
            task:                    .translate,   // 🇹🇭 → 🇬🇧 in one pass
            language:                "th",
            temperature:             0.0,
            temperatureFallbackCount: 0,
            topK:                    5,
            usePrefillPrompt:        true,
            detectLanguage:          false,
            skipSpecialTokens:       true,
            withoutTimestamps:       true,
            suppressorBlank:          true,
            noSpeechThreshold:       0.6   // discard near-silence frames
        )
    }

    // MARK: - Setup (Phase 3.1 – 3.3)

    /// Downloads (first run only) and loads the CoreML model on ANE.
    func setup() async {
        switch state {
        case .idle, .failed: break
        case .loading, .ready: return   // already loaded or in progress
        case .inferring:
            // Wait until inference finishes before allowing a reload.
            // Callers (e.g. Settings "Retry") should disable the button while
            // state == .inferring to avoid reaching this branch.
            return
        }
        state = .loading
        do {
            let cfg = WhisperKitConfig(
                model: modelName,
                computeOptions: ModelComputeOptions(
                    audioEncoderCompute: .cpuAndNeuralEngine,   // ANE for encoder
                    textDecoderCompute:  .cpuAndNeuralEngine
                ),
                verbose:  false,
                logLevel: .none,
                prewarm:  true,
                load:     true,
                download: true
            )
            kit   = try await WhisperKit(cfg)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Inference (Phase 4.1 – 4.4)

    /// Accepts 16 kHz mono Float32 PCM and returns English text.
    func translate(_ samples: [Float]) async throws -> String {
        guard let wk = kit else { throw WhisperError.notReady }
        state = .inferring
        defer { if state == .inferring { state = .ready } }

        let results = try await wk.transcribe(
            audioArray:    samples,
            decodeOptions: decodeOptions
        )

        let raw = results
            .map(\.text)
            .joined(separator: " ")

        // Strip Whisper control tokens like [BLANK_AUDIO], (Music), etc.
        let cleaned = raw
            .replacingOccurrences(of: #"[\(\[][^\)\]]{1,30}[\)\]]"#,
                                   with: "",
                                   options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "  +", with: " ",
                                   options: .regularExpression)

        return cleaned
    }
}

enum WhisperError: LocalizedError {
    case notReady
    var errorDescription: String? { "Whisper model is not loaded." }
}