import SwiftUI
import Foundation
@preconcurrency import AVFoundation
import Speech
import Observation

// MARK: - Types

enum TranslationEngineType: String, CaseIterable, Identifiable {
    case auto  = "Auto"
    case apple = "Apple ASR"   // SFSpeechRecognizer fallback
    var id: String { rawValue }
}

struct LogEntry: Identifiable, Sendable {
    let id   = UUID()
    let text: String
}

struct TranslationMessage: Identifiable {
    let id        = UUID()
    let english:    String
    let engine:     String
    let timestamp   = Date()
}

// MARK: - Engine

@Observable
@MainActor
final class TranslatorEngine: NSObject {

    // ── UI state ──────────────────────────────────────────────────────────
    var isListening    = false
    var isProcessing   = false
    var isReady        = false
    var audioLevel:    Float = 0
    var statusLabel    = "Initialising…"
    var debugLog:      [LogEntry] = []
    var errorMessage:  String?
    var liveTranscript = ""
    var messages:      [TranslationMessage] = []

    // ── Sub-engines ───────────────────────────────────────────────────────
    let qwenEngine   = QwenEngine()
    let appleEngine  = AppleTranslationEngine()

    @ObservationIgnored
    private var _enginePreference: TranslationEngineType {
        get {
            let raw = UserDefaults.standard.string(forKey: AppStorageKeys.preferredEngine) ?? ""
            return TranslationEngineType(rawValue: raw) ?? .auto
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: AppStorageKeys.preferredEngine) }
    }
    var enginePreference: TranslationEngineType {
        get { access(keyPath: \.enginePreference); return _enginePreference }
        set { withMutation(keyPath: \.enginePreference) { _enginePreference = newValue } }
    }

    @ObservationIgnored
    private var _showDebugLog: Bool {
        get { UserDefaults.standard.bool(forKey: AppStorageKeys.showDebugLog) }
        set { UserDefaults.standard.set(newValue, forKey: AppStorageKeys.showDebugLog) }
    }
    var showDebugLog: Bool {
        get { access(keyPath: \.showDebugLog); return _showDebugLog }
        set { withMutation(keyPath: \.showDebugLog) { _showDebugLog = newValue } }
    }

    var exportableLog: String { debugLog.map(\.text).joined(separator: "\n") }

    // ── History ───────────────────────────────────────────────────────────
    var store               = ConversationStore()
    private var currentConversation = StoredConversation()

    // ── Audio ─────────────────────────────────────────────────────────────
    private let audioEngine  = AVAudioEngine()
    private let audioQueue   = DispatchQueue(label: "com.rt.audioQueue", qos: .userInteractive)
    private var nativeSampleRate: Double = 44_100
    private var rawSpeechBuffer: [Float] = []
    private var pendingChunk: [Float]?

    // ── VAD (tuned for small chunks) ──────────────────────────────────────
    private var isSpeechActive = false
    private var silenceStart:  Date?
    private var speechStart:   Date?
    private let silenceDB:     Float        = -40    // slightly more sensitive
    private let silenceDur:    TimeInterval = 0.8    // commit after 0.8 s silence (was 1.2)
    private let minSpeechDur:  TimeInterval = 0.3    // ignore clips < 0.3 s (was 0.4)

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                if self?.isListening == true { self?.stopListening() }
            }
        }
    }

    // MARK: - Boot

    func boot() async {
        statusLabel = "Requesting permissions…"
        guard await requestPermissions() else { return }

        statusLabel = "Loading Qwen3-ASR model (~0.6 GB first run)…"
        log("Starting Qwen3 setup")
        await qwenEngine.setup()

        switch qwenEngine.state {
        case .ready:
            log("Qwen3-ASR ready")
        case .failed(let e):
            log("Qwen3 failed: \(e) — Apple ASR active as fallback")
        default: break
        }

        isReady     = true
        statusLabel = ""
    }

    // MARK: - Permissions

    private func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization {
                cont.resume(returning: $0 == .authorized)
            }
        }
        guard speech else { errorMessage = "Speech recognition permission denied."; return false }
        let mic = await AVAudioApplication.requestRecordPermission()
        guard mic else { errorMessage = "Microphone permission denied."; return false }
        return true
    }

    // MARK: - Mic toggle

    func toggleListening() { isListening ? stopListening() : startListening() }

    private func startListening() {
        do {
            try startAudio()
            isListening         = true
            currentConversation = StoredConversation()
            liveTranscript      = ""
            log("Listening…")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        rawSpeechBuffer = []
        pendingChunk    = nil
        isSpeechActive  = false
        silenceStart    = nil
        speechStart     = nil
        isListening     = false
        audioLevel      = 0
        liveTranscript  = ""
        try? AVAudioSession.sharedInstance()
             .setActive(false, options: .notifyOthersOnDeactivation)
        store.upsert(currentConversation)
        log("Stopped")
    }

    // MARK: - Audio engine

    private func startAudio() throws {
        let av = AVAudioSession.sharedInstance()
        try av.setCategory(.playAndRecord, mode: .measurement,
                           options: [.allowBluetooth, .defaultToSpeaker])
        try av.setActive(true)

        let input        = audioEngine.inputNode
        let nativeFormat = input.outputFormat(forBus: 0)
        nativeSampleRate = nativeFormat.sampleRate

        let chCount = max(1, nativeFormat.channelCount)
        let format  = AVAudioFormat(standardFormatWithSampleRate: nativeFormat.sampleRate,
                                    channels: chCount)!
        log("Audio SR=\(Int(nativeSampleRate)) ch=\(chCount)")

        input.installTap(onBus: 0, bufferSize: 1024, format: format) {
            [weak self] buf, _ in
            guard let self, let ch = buf.floatChannelData?[0] else { return }
            let n       = Int(buf.frameLength)
            let samples = Array(UnsafeBufferPointer(start: ch, count: n))

            self.audioQueue.async {
                var sum: Float = 0
                for i in 0..<n { sum += samples[i] * samples[i] }
                let rms = sqrt(sum / Float(max(n, 1)))
                let db  = 20 * log10(max(rms, 1e-10))
                let lvl = max(0, min(1, (db + 60) / 60))
                Task { @MainActor [weak self] in
                    self?.onAudio(samples: samples, db: db, level: lvl)
                }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    // MARK: - VAD

    private func onAudio(samples: [Float], db: Float, level: Float) {
        audioLevel = level
        let now    = Date()

        if db > silenceDB {
            if !isSpeechActive {
                isSpeechActive = true
                speechStart    = now
                liveTranscript = "🎤 Listening…"
            }
            silenceStart = nil
            rawSpeechBuffer.append(contentsOf: samples)
            if rawSpeechBuffer.count > Int(nativeSampleRate * 20) { commitChunk() }
        } else if isSpeechActive {
            rawSpeechBuffer.append(contentsOf: samples)
            if silenceStart == nil {
                silenceStart = now
            } else if let ss = silenceStart, now.timeIntervalSince(ss) >= silenceDur {
                let len = speechStart.map { now.timeIntervalSince($0) } ?? 0
                if len >= minSpeechDur { commitChunk() } else { resetBuffer() }
            }
        }
    }

    private func commitChunk() {
        guard !rawSpeechBuffer.isEmpty else { return }
        let raw     = rawSpeechBuffer
        let srcRate = nativeSampleRate
        resetBuffer()

        let s16k = resampleLinear(raw, from: srcRate, to: 16_000)

        guard !isProcessing else {
            pendingChunk = s16k
            log("Queued chunk (busy)")
            return
        }
        Task { await process(samples: s16k) }
    }

    private func resetBuffer() {
        rawSpeechBuffer = []
        isSpeechActive  = false
        silenceStart    = nil
        speechStart     = nil
        liveTranscript  = ""
    }

    // MARK: - Resampling

    private func resampleLinear(_ src: [Float], from: Double, to: Double) -> [Float] {
        guard from != to, !src.isEmpty else { return src }
        let ratio = from / to
        let outN  = Int(Double(src.count) / ratio)
        var out   = [Float](repeating: 0, count: outN)
        for i in 0..<outN {
            let pos = Double(i) * ratio
            let idx = Int(pos)
            let frc = Float(pos - Double(idx))
            out[i] = idx + 1 < src.count
                ? src[idx] + frc * (src[idx + 1] - src[idx])
                : src[min(idx, src.count - 1)]
        }
        return out
    }

    // MARK: - Process: Qwen3 ASR → Apple Translate

    private func process(samples: [Float]) async {
        isProcessing = true
        defer {
            isProcessing = false
            if let next = pendingChunk {
                pendingChunk = nil
                Task { await self.process(samples: next) }
            }
        }

        do {
            // ── Step 1: Thai ASR ──────────────────────────────────────────
            liveTranscript = "⟳ Transcribing…"
            let tel = TelemetryLogger()
            tel.start("asr")
            let thaiText = try await qwenEngine.transcribe(samples)
            tel.end("asr", engine: "qwen3")

            guard !thaiText.isEmpty else { liveTranscript = ""; return }
            log("[qwen3] Thai: \(thaiText.prefix(60))")

            // ── Step 2: Thai → English ────────────────────────────────────
            liveTranscript = "⟳ Translating…"
            tel.start("translate")
            let english = try await appleEngine.translate(thaiText)
            tel.end("translate", engine: "apple")

            guard !english.isEmpty else { liveTranscript = ""; return }

            liveTranscript = ""
            let msg = TranslationMessage(english: english, engine: "qwen3")
            messages.append(msg)
            currentConversation.messages.append(StoredMessage(english: english, engine: "qwen3"))
            store.upsert(currentConversation)
            log("[qwen3→apple] \(english.prefix(60))")

        } catch {
            liveTranscript = ""
            log("Error: \(error.localizedDescription)")
        }
    }

    // MARK: - Debug

    private func log(_ msg: String) {
        let ts    = Date().formatted(.dateTime.hour().minute().second())
        let entry = LogEntry(text: "[\(ts)] \(msg)")
        debugLog.append(entry)
        if debugLog.count > 500 { debugLog.removeFirst() }
        print("RT: \(msg)")
    }
}
