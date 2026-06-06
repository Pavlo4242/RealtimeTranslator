import Foundation
import AVFoundation
import Speech
import Translation
import Observation

/// Apple on-device fallback: Thai SFSpeechRecognizer → Apple Translation (iOS 18+).
/// ContentView must attach `.translationTask(appleEngine.translationConfig)` to trigger sessions.
@Observable
@MainActor
final class AppleTranslationEngine {

    // SwiftUI observes this; setting it triggers .translationTask in ContentView
    var translationConfig: TranslationSession.Configuration?
    var isAvailable = false

    private let recognizerTH = SFSpeechRecognizer(locale: Locale(identifier: "th-TH"))
    private var sessionContinuation: CheckedContinuation<String, Error>?
    private var pendingText = ""

    // MARK: - Setup

    func setup() async {
        isAvailable = recognizerTH?.isAvailable == true
    }

    // MARK: - Public entry point

    /// Accepts 16 kHz mono Float32 PCM. Returns English text.
    func translateAudio(_ samples: [Float]) async throws -> String {
        guard let rec = recognizerTH, rec.isAvailable else {
            throw AppleEngineError.unavailable
        }
        // Step 1 – ASR: Float32 PCM → Thai text
        let thaiText = try await recogniseThai(samples, recognizer: rec)
        guard !thaiText.isEmpty else { throw AppleEngineError.emptyASR }

        // Step 2 – Translate: Thai text → English via Translation framework
        return try await translateText(thaiText)
    }

    // MARK: - Thai ASR

    private func recogniseThai(_ samples: [Float],
                                recognizer: SFSpeechRecognizer) async throws -> String {
        let url = FileManager.default.temporaryDirectory
                  .appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try writePCMWAV(samples: samples, sampleRate: 16_000, to: url)

        return try await withCheckedThrowingContinuation { cont in
            let req = SFSpeechURLRecognitionRequest(url: url)
            req.requiresOnDeviceRecognition = true
            req.shouldReportPartialResults  = false

            var settled = false
            recognizer.recognitionTask(with: req) { result, error in
                guard !settled else { return }
                if let error {
                    settled = true; cont.resume(throwing: error)
                } else if let r = result, r.isFinal {
                    settled = true
                    cont.resume(returning: r.bestTranscription.formattedString)
                }
            }
        }
    }

    // MARK: - Translation session (SwiftUI-driven)

    private func translateText(_ thai: String) async throws -> String {
        // Cancel any in-flight translation BEFORE overwriting pendingText,
        // so the displaced continuation always sees the text it was created for.
        if let existing = sessionContinuation {
            existing.resume(throwing: CancellationError())
            sessionContinuation = nil
            translationConfig   = nil
        }
        pendingText = thai
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { [weak self] cont in
                guard let self else { cont.resume(throwing: CancellationError()); return }
                self.sessionContinuation = cont
                // Setting this triggers .translationTask in ContentView
                self.translationConfig = TranslationSession.Configuration(
                    source: Locale.Language(identifier: "th"),
                    target: Locale.Language(identifier: "en")
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    /// Called by ContentView's .translationTask modifier.
    func handleSession(_ session: TranslationSession) async {
        guard let cont = sessionContinuation else { return }
        sessionContinuation = nil
        do {
            let r = try await session.translate(pendingText)
            cont.resume(returning: r.targetText)
        } catch {
            cont.resume(throwing: error)
        }
        translationConfig = nil
    }

    func cancel() {
        sessionContinuation?.resume(throwing: CancellationError())
        sessionContinuation = nil
        translationConfig   = nil
    }

    // MARK: - WAV writer

    private func writePCMWAV(samples: [Float], sampleRate: Int, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey:             kAudioFormatLinearPCM,
            AVSampleRateKey:           Float(sampleRate),
            AVNumberOfChannelsKey:     1,
            AVLinearPCMBitDepthKey:    32,
            AVLinearPCMIsFloatKey:     true,
            AVLinearPCMIsBigEndianKey: false
        ]
        let file = try AVAudioFile(forWriting: url,
                                   settings: settings,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)

        let cap = AVAudioFrameCount(samples.count)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                          frameCapacity: cap) else {
            throw AppleEngineError.bufferFailed
        }
        buf.frameLength = cap
        samples.withUnsafeBufferPointer {
            buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        try file.write(from: buf)
    }
}

enum AppleEngineError: LocalizedError {
    case unavailable, emptyASR, bufferFailed
    var errorDescription: String? {
        switch self {
        case .unavailable:  return "Thai speech recognizer is not available on this device."
        case .emptyASR:     return "No speech detected."
        case .bufferFailed: return "Audio buffer error."
        }
    }
}