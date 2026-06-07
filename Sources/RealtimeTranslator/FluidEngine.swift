import Foundation
import Observation
import FluidAudio

@Observable
@MainActor
final class FluidEngine {

    // Mirrors WhisperEngineState so TranslatorEngine.boot() needs no changes
    var state: WhisperEngineState = .idle

    var isReady: Bool { state == .ready }

    private var asr: SlidingWindowAsrManager?

    // MARK: - Setup  (called once from TranslatorEngine.boot())

    func setup() async {
        switch state {
        case .idle, .failed: break
        case .loading, .ready, .inferring: return
        }
        state = .loading
        do {
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let mgr = SlidingWindowAsrManager(config: .default)
            try await mgr.loadModels(models)
            self.asr = mgr
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Inference  (same signature as WhisperEngine.translate)

    func translate(_ samples: [Float]) async throws -> String {
        guard let asr else { throw WhisperError.notReady }
        state = .inferring
        defer { if state == .inferring { state = .ready } }

        // Feed samples as a one-shot buffer via a temporary AVAudioPCMBuffer
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16_000,
                                   channels: 1,
                                   interleaved: false)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(samples.count))
        else { throw WhisperError.notReady }
        buf.frameLength = AVAudioFrameCount(samples.count)
        buf.floatChannelData![0].update(from: samples, count: samples.count)

        try await asr.startStreaming()
        await asr.streamAudio(buf)
        let text = try await asr.finish()
        try await asr.reset()

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
