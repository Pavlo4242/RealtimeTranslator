import Foundation
import AVFoundation
import Observation
import FluidAudio

@Observable
@MainActor
final class FluidEngine {

    var state: WhisperEngineState = .idle
    var isReady: Bool { state == .ready }

    private var manager: Qwen3AsrManager?

    // MARK: - Setup  (called once from TranslatorEngine.boot())

    func setup() async {
        switch state {
        case .idle, .failed: break
        case .loading, .ready, .inferring: return
        }
        state = .loading
        do {
            // INT8 halves RAM (~600 MB vs ~1.1 GB) with minimal accuracy loss
            manager = try await Qwen3AsrManager(variant: .int8)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Inference  (same signature as WhisperEngine.translate)

    func translate(_ samples: [Float]) async throws -> String {
        guard let manager else { throw WhisperError.notReady }
        state = .inferring
        defer { if state == .inferring { state = .ready } }

        // samples are already 16 kHz mono Float32 from TranslatorEngine.resampleLinear
        let text = try await manager.transcribe(samples)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
