import SwiftUI
import Foundation
@preconcurrency import AVFoundation
import Speech
import Observation

// MARK: - Types

enum TranslationEngineType: String, CaseIterable, Identifiable {
    case auto    = "Auto"
    case whisper = "Whisper (ANE)"
    case apple   = "Apple Translate"
    var id: String { rawValue }
}

struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let text: String
}

struct TranslationMessage: Identifiable {
    let id        = UUID()
    let english:    String
    let engine:     String     // "whisper" | "apple"
    let timestamp   = Date()
}

// MARK: - Engine

@Observable
@MainActor
final class TranslatorEngine: NSObject {

    // ── UI state ──────────────────────────────────────────────────────────
    var isListening  = false
    var isProcessing = false
    var isReady      = false
    var audioLevel:  Float = 0
    var statusLabel  = "Initialising…"
    var debugLog:    [LogEntry] = []
    var errorMessage: String?
    var liveTranscript = ""          // "🎤 Listening…" / "⟳ Translating…"
    var messages:    [TranslationMessage] = []

    // ── Sub-engines ───────────────────────────────────────────────────────
    var whisperEngine = WhisperEngine()
    let appleEngine   = AppleTranslationEngine()

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

    var exportableLog: String {
        debugLog.map(\.text).joined(separator: "\n")
    }

    var store = ConversationStore()
    private var currentConversation = StoredConversation()

    // ── Audio ─────────────────────────────────────────────────────────────
    private let audioEngine   = AVAudioEngine()
    private let audioQueue    = DispatchQueue(label: "com.rt.audioQueue", qos: .userInteractive)
    private var nativeSampleRate: Double = 44_100
    private var rawSpeechBuffer: [Float] = []
    /// Holds at most one chunk that arrived while processing was busy.
    /// When the current translation finishes, this chunk is processed next.
    private var pendingChunk: [Float]?

    // ── VAD ───────────────────────────────────────────────────────────────
    private var isSpeechActive  = false
    private var silenceStart:   Date?
    private var speechStart:    Date?
    private let silenceDB:      Float = -42        // threshold dB
    private let silenceDur:     TimeInterval = 1.2 // silence → commit
    private let minSpeechDur:   TimeInterval = 0.4 // ignore clips shorter than this

    override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self = self,
                  let info = notification.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            if type == .began {
                Task { @MainActor in
                    self.log("AVAudioSession interruption began. Stopping audio.")
                    if self.isListening { self.stopListening() }
                }
            }
        }
    }

    // MARK: - Boot

    func boot() async {
        statusLabel = "Requesting permissions…"
        guard await requestPermissions() else { return }

        statusLabel = "Loading Whisper model (first run downloads ~500 MB)…"
        log("Starting Whisper setup")
        await whisperEngine.setup()

        // Always set up Apple engine so it is available for manual selection
        // and as a Whisper fallback, regardless of Whisper's result.
        await appleEngine.setup()

        switch whisperEngine.state {
        case .ready:
            log("Whisper ready")
        case .failed(let e):
            log("Whisper failed: \(e)")
            if appleEngine.isAvailable {
                log("Apple engine ready (fallback)")
            } else {
                errorMessage = "No translation engine available on this device."
                return
            }
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
        guard speech else {
            errorMessage = "Speech recognition permission denied."
            return false
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        guard mic else {
            errorMessage = "Microphone permission denied."
            return false
        }
        return true
    }

    // MARK: - Mic toggle

    func toggleListening() {
        isListening ? stopListening() : startListening()
    }

    private func startListening() {
        do {
            try startAudio()
            isListening          = true
            currentConversation  = StoredConversation()
            liveTranscript       = ""
            log("Listening for Thai speech…")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopListening() {
        // Stop the audio pipeline first so no further callbacks can append
        // to currentConversation after we persist it.
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
        // Persist after the tap is removed — snapshot is now stable.
        store.upsert(currentConversation)
        log("Stopped")
    }

    // MARK: - Audio engine (Phase 2.1 – 2.3)

    private func startAudio() throws {
        let av = AVAudioSession.sharedInstance()
        try av.setCategory(.playAndRecord, mode: .measurement,
                           options: [.allowBluetooth, .defaultToSpeaker])
        try av.setActive(true)

        let input        = audioEngine.inputNode
        let nativeFormat = input.outputFormat(forBus: 0)
        nativeSampleRate = nativeFormat.sampleRate    // store for resampling

        let chCount = max(1, nativeFormat.channelCount)
        let format = AVAudioFormat(standardFormatWithSampleRate: nativeFormat.sampleRate, channels: chCount)!
        
        log("startAudio: SR=\(nativeSampleRate), channels=\(chCount)")

        input.installTap(onBus: 0, bufferSize: 1024, format: format) {
            [weak self] buf, _ in
            guard let self else { return }

            self.audioQueue.async {
                guard let ch = buf.floatChannelData?[0] else { return }
                let n = Int(buf.frameLength)

                // Compute RMS on audio thread (no actor hop for simple maths)
                var sum: Float = 0
                for i in 0..<n { sum += ch[i] * ch[i] }
                let rms  = sqrt(sum / Float(max(n, 1)))
                let db   = 20 * log10(max(rms, 1e-10))
                let lvl  = max(0, min(1, (db + 60) / 60))

                let samples = Array(UnsafeBufferPointer(start: ch, count: n))
                Task { @MainActor [weak self] in
                    self?.onAudio(samples: samples, db: db, level: lvl)
                }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    // MARK: - VAD + buffer management

    private func onAudio(samples: [Float], db: Float, level: Float) {
        audioLevel = level
        let now    = Date()

        if db > silenceDB {
            // ── Active speech ─────────────────────────────────────────────
            if !isSpeechActive {
                isSpeechActive = true
                speechStart    = now
                liveTranscript = "🎤 Listening…"
                log("VAD: Speech started")
            }
            silenceStart = nil
            rawSpeechBuffer.append(contentsOf: samples)

            // Hard cap: flush at 30 s to avoid huge buffers
            if rawSpeechBuffer.count > Int(nativeSampleRate * 30) {
                commitChunk()
            }

        } else {
            // ── Silence ───────────────────────────────────────────────────
            if isSpeechActive {
                rawSpeechBuffer.append(contentsOf: samples)   // include trailing silence

                if silenceStart == nil {
                    silenceStart = now
                } else if let ss = silenceStart,
                          now.timeIntervalSince(ss) >= silenceDur {
                    let speechLen = speechStart.map { now.timeIntervalSince($0) } ?? 0
                    if speechLen >= minSpeechDur {
                        commitChunk()
                    } else {
                        resetBuffer()        // too short (cough, noise)
                        log("VAD: Speech too short, ignored")
                    }
                }
            }
        }
    }

    private func commitChunk() {
        guard !rawSpeechBuffer.isEmpty else { return }
        log("commitChunk: flushing \(rawSpeechBuffer.count) samples")
        let raw = rawSpeechBuffer
        resetBuffer()

        let srcRate = nativeSampleRate
        guard !isProcessing else {
            // Buffer the latest chunk; older buffered chunk is discarded.
            log("Queued chunk (was busy); previous pending chunk replaced if any")
            let s16k = resampleLinear(raw, from: srcRate, to: 16_000)
            pendingChunk = s16k
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let s16k = resampleLinear(raw, from: srcRate, to: 16_000)
            await self.process(samples: s16k)
        }
    }

    private func resetBuffer() {
        rawSpeechBuffer = []
        isSpeechActive  = false
        silenceStart    = nil
        speechStart     = nil
        liveTranscript  = ""
    }

    // MARK: - Resampling (16 kHz for Whisper)

    private func resampleLinear(_ src: [Float], from: Double, to: Double) -> [Float] {
        guard from != to, !src.isEmpty else { return src }
        let ratio = from / to                          // e.g. 44100/16000 ≈ 2.756
        let outN  = Int(Double(src.count) / ratio)
        var out   = [Float](repeating: 0, count: outN)
        for i in 0..<outN {
            let pos = Double(i) * ratio
            let idx = Int(pos)
            let frc = Float(pos - Double(idx))
            out[i]  = idx + 1 < src.count
                ? src[idx] + frc * (src[idx + 1] - src[idx])
                : src[min(idx, src.count - 1)]
        }
        return out
    }

    // MARK: - Translation dispatch (Phase 4 / Phase 6)

    private func process(samples: [Float]) async {
        isProcessing   = true
        liveTranscript = "⟳ Translating…"
        defer {
            isProcessing = false
            // Drain the pending chunk, if any arrived while we were busy.
            if let next = pendingChunk {
                pendingChunk = nil
                Task { await self.process(samples: next) }
            }
        }

        let tel    = TelemetryLogger()
        let useKit: Bool = {
            switch enginePreference {
            case .whisper: return whisperEngine.isReady
            case .apple:   return false
            case .auto:    return whisperEngine.isReady
            }
        }()

        do {
            tel.start("translate")
            let text: String
            let engineTag: String

            if useKit {
                text      = try await whisperEngine.translate(samples)
                engineTag = "whisper"
            } else {
                text      = try await appleEngine.translateAudio(samples)
                engineTag = "apple"
            }
            tel.end("translate", engine: engineTag)

            guard !text.isEmpty else {
                liveTranscript = ""
                return
            }

            liveTranscript = ""
            let msg = TranslationMessage(english: text, engine: engineTag)
            messages.append(msg)
            currentConversation.messages.append(
                StoredMessage(english: text, engine: engineTag)
            )
            store.upsert(currentConversation)
            log("[\(engineTag)] \(text.prefix(60))")

        } catch {
            liveTranscript = ""
            // Whisper failed → try Apple fallback once (Phase 6.2 / 6.3)
            if useKit && appleEngine.isAvailable {
                log("Whisper error, retrying with Apple: \(error.localizedDescription)")
                do {
                    let text = try await appleEngine.translateAudio(samples)
                    if !text.isEmpty {
                        let msg = TranslationMessage(english: text, engine: "apple-fallback")
                        messages.append(msg)
                        currentConversation.messages.append(
                            StoredMessage(english: text, engine: "apple-fallback")
                        )
                        store.upsert(currentConversation)
                    }
                } catch {
                    log("Fallback also failed: \(error.localizedDescription)")
                }
            } else {
                log("Translation error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Debug

    private func log(_ msg: String) {
        let ts = Date().formatted(.dateTime.hour().minute().second())
        let entry = LogEntry(text: "[\(ts)] \(msg)")
        debugLog.append(entry)
        if debugLog.count > 500 { debugLog.removeFirst() }
        print("RT: \(msg)")
    }
}