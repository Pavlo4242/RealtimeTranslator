//
//  RecognitionService.swift
//  Translator
//
//  Replaces Apple SpeechAnalyzer/SpeechTranscriber with FluidAudio
//  SlidingWindowAsrManager. Public interface is unchanged:
//    • start() async throws
//    • ingest(_ buffer: AVAudioPCMBuffer)
//    • stop() async
//    • events: AsyncStream<RecognitionEvent>
//

import AVFoundation
import FluidAudio

actor RecognitionService {

    // MARK: - Public event stream (same shape as before)
    private var eventsContinuation: AsyncStream<RecognitionEvent>.Continuation?
    let events: AsyncStream<RecognitionEvent>

    // MARK: - FluidAudio internals
    private var asr: SlidingWindowAsrManager?

    init() {
        var continuation: AsyncStream<RecognitionEvent>.Continuation!
        self.events = AsyncStream { events in continuation = events }
        self.eventsContinuation = continuation
    }

    // MARK: - start

    func start() async throws {
        let models = try await AsrModels.downloadAndLoad(version: .v3)

        let asr = SlidingWindowAsrManager(config: .default)
        try await asr.loadModels(models)
        try await asr.startStreaming()
        self.asr = asr

        print("[Recognition] FluidAudio ASR started")

        // Pump transcription updates → RecognitionEvent stream
        Task { [weak self] in
            guard let self else { return }
            for await update in await asr.transcriptionUpdates {
                let text = update.text
                guard !text.isEmpty else { continue }
                if update.isConfirmed {
                    print("[Recognition] FINAL: \"\(text)\"")
                    await self.eventsContinuation?.yield(.final(text))
                } else {
                    print("[Recognition] PARTIAL: \"\(text)\"")
                    await self.eventsContinuation?.yield(.partial(text))
                }
            }
            print("[Recognition] transcriptionUpdates stream ended")
        }
    }

    // MARK: - ingest  (AVAudioPCMBuffer from MicCapture — unchanged signature)

    func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let asr else { return }
        // FluidAudio handles format conversion to 16 kHz mono Float32 internally.
        Task { await asr.streamAudio(buffer) }
    }

    // MARK: - stop

    func stop() async {
        if let asr {
            _ = try? await asr.finish()
            try? await asr.reset()
        }
        asr = nil
        eventsContinuation?.finish()
        eventsContinuation = nil
    }
}
