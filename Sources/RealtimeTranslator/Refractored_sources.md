# RealtimeTranslator Refactor — Thai Audio → English Script

**Target:** On-device, real-time Thai speech → English text  
**Primary engine:** WhisperKit (whisper.cpp + CoreML / ANE) via SPM  
**Fallback engine:** SFSpeechRecognizer (th-TH) + Apple Translation framework  
**Action required before committing:**  
- Delete `Sources/RealtimeTranslator/AppleTranslator.swift` (replaced by `AppleTranslationEngine.swift`)

---

## `.github/workflows/build.yml`

```yaml
name: Build IPA

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  build:
    name: Build ad-hoc signed IPA
    runs-on: macos-15

    steps:
      # ── 1. Checkout ─────────────────────────────────────────────────────
      - name: Checkout
        uses: actions/checkout@v4

      # ── 2. Xcode ─────────────────────────────────────────────────────────
      - name: Select Xcode 16
        run: sudo xcode-select -s /Applications/Xcode_16.2.app/Contents/Developer

      # ── 3. XcodeGen ──────────────────────────────────────────────────────
      - name: Install XcodeGen
        run: brew install xcodegen

      - name: Generate .xcodeproj
        run: xcodegen generate --spec project.yml

      # ── 4. SPM resolution ────────────────────────────────────────────────
      # WhisperKit (~500 MB of CoreML weights) is downloaded at app runtime,
      # not at build time, so CI only needs to resolve the Swift package graph.
      - name: Resolve SPM dependencies
        run: |
          xcodebuild \
            -resolvePackageDependencies \
            -project RealtimeTranslator.xcodeproj \
            -scheme RealtimeTranslator \
            -clonedSourcePackagesDirPath "$RUNNER_TEMP/spm"

      # ── 5. Build ──────────────────────────────────────────────────────────
      - name: Build
        run: |
          xcodebuild \
            -project RealtimeTranslator.xcodeproj \
            -scheme RealtimeTranslator \
            -destination 'generic/platform=iOS' \
            -configuration Release \
            -derivedDataPath "$RUNNER_TEMP/DerivedData" \
            -clonedSourcePackagesDirPath "$RUNNER_TEMP/spm" \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGN_IDENTITY=""

      # ── 6. Ad-hoc sign + package IPA ─────────────────────────────────────
      - name: Package IPA
        run: |
          APP=$(find "$RUNNER_TEMP/DerivedData" -name "*.app" \
                ! -path "*iphonesimulator*" | head -1)
          echo "App bundle: $APP"
          codesign --force --deep --sign "-" "$APP"
          mkdir -p Payload
          cp -r "$APP" Payload/RealtimeTranslator.app
          zip -r RealtimeTranslator.ipa Payload
          echo "IPA size: $(du -sh RealtimeTranslator.ipa | cut -f1)"

      # ── 7. Upload artifact ────────────────────────────────────────────────
      - name: Upload IPA
        uses: actions/upload-artifact@v4
        with:
          name: RealtimeTranslator-IPA
          path: RealtimeTranslator.ipa
          retention-days: 14
          if-no-files-found: error
```

---

## `project.yml`

```yaml
name: RealtimeTranslator

options:
  bundleIdPrefix: com.realtimetranslator
  deploymentTarget:
    iOS: "18.0"
  createIntermediateGroups: true
  xcodeVersion: "16"

# ── SPM packages ─────────────────────────────────────────────────────────────
packages:
  WhisperKit:
    url: https://github.com/argmaxinc/WhisperKit
    from: "0.9.0"

settings:
  base:
    SWIFT_VERSION: "5.10"
    ENABLE_BITCODE: NO
    DEBUG_INFORMATION_FORMAT: dwarf-with-dsym

targets:
  RealtimeTranslator:
    type: application
    platform: iOS
    deploymentTarget: "18.0"

    sources:
      - path: Sources/RealtimeTranslator
        type: group
        excludes:
          - AppleTranslator.swift   # deleted; replaced by AppleTranslationEngine.swift

    resources:
      - Resources/Assets.xcassets

    # WhisperKit provides whisper.cpp + CoreML encoder for ANE
    dependencies:
      - package: WhisperKit
        product: WhisperKit

    info:
      path: Resources/Info.plist

    entitlements:
      path: Resources/RealtimeTranslator.entitlements

    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.realtimetranslator.app
        INFOPLIST_FILE: Resources/Info.plist
        CODE_SIGN_ENTITLEMENTS: Resources/RealtimeTranslator.entitlements
        TARGETED_DEVICE_FAMILY: "1,2"
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        MARKETING_VERSION: "1.0"
        CURRENT_PROJECT_VERSION: "1"
```

---

## `Resources/Info.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSMicrophoneUsageDescription</key>
    <string>RealtimeTranslator listens to Thai speech to translate it into English.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Used by the Apple Translate fallback engine to recognise Thai speech on-device.</string>
    <key>UIBackgroundModes</key>
    <array>
        <string>audio</string>
    </array>
    <key>UILaunchScreen</key>
    <dict/>
    <key>UIRequiredDeviceCapabilities</key>
    <array>
        <string>arm64</string>
    </array>
    <key>UISupportedInterfaceOrientations</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
    </array>
    <key>UISupportedInterfaceOrientations~ipad</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationPortraitUpsideDown</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
</dict>
</plist>
```

---

## `Resources/RealtimeTranslator.entitlements`

*(unchanged — keep the speech-recognition entitlement)*

---

## `Sources/RealtimeTranslator/AppStorageKeys.swift`  *(NEW)*

```swift
import Foundation

enum AppStorageKeys {
    static let preferredEngine = "preferredEngine"   // TranslationEngineType.rawValue
    static let showDebugLog    = "showDebugLog"
}
```

---

## `Sources/RealtimeTranslator/TelemetryLogger.swift`  *(NEW)*

```swift
import Foundation
import os

/// Lightweight per-event wall-clock timer; thread-safe.
final class TelemetryLogger: Sendable {

    private let log = Logger(subsystem: "com.realtimetranslator", category: "telemetry")
    private let lock = OSAllocatedUnfairLock(initialState: [String: Date]())

    func start(_ event: String) {
        lock.withLock { $0[event] = Date() }
    }

    func end(_ event: String, engine: String) {
        let elapsed = lock.withLock { dict -> TimeInterval? in
            guard let t = dict.removeValue(forKey: event) else { return nil }
            return Date().timeIntervalSince(t)
        }
        guard let ms = elapsed else { return }
        log.info("[\(engine, privacy: .public)] \(event, privacy: .public): \(Int(ms * 1000), privacy: .public)ms")
    }
}
```

---

## `Sources/RealtimeTranslator/WhisperEngine.swift`  *(NEW — Phase 3 & 4)*

```swift
import Foundation
import WhisperKit
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
            suppressBlank:           true,
            noSpeechThreshold:       0.6   // discard near-silence frames
        )
    }

    // MARK: - Setup (Phase 3.1 – 3.3)

    /// Downloads (first run only) and loads the CoreML model on ANE.
    func setup() async {
        switch state {
        case .idle, .failed: break
        default: return
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

        let raw = (results ?? [])
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
```

---

## `Sources/RealtimeTranslator/AppleTranslationEngine.swift`  *(NEW — Phase 6)*

```swift
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
        pendingText = thai
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { [weak self] cont in
                guard let self else { cont.resume(throwing: CancellationError()); return }
                self.sessionContinuation?.resume(throwing: CancellationError())
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
```

---

## `Sources/RealtimeTranslator/TranslatorEngine.swift`  *(FULL REWRITE — Phase 2)*

```swift
import Foundation
import AVFoundation
import Speech
import Observation

// MARK: - Types

enum TranslationEngineType: String, CaseIterable, Identifiable {
    case auto    = "Auto"
    case whisper = "Whisper (ANE)"
    case apple   = "Apple Translate"
    var id: String { rawValue }
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
    var debugLog:    [String] = []
    var errorMessage: String?
    var liveTranscript = ""          // "🎤 Listening…" / "⟳ Translating…"
    var messages:    [TranslationMessage] = []

    // ── Sub-engines ───────────────────────────────────────────────────────
    let whisperEngine = WhisperEngine()
    let appleEngine   = AppleTranslationEngine()
    var enginePreference: TranslationEngineType = .auto

    // ── History ───────────────────────────────────────────────────────────
    var store = ConversationStore()
    private var currentConversation = StoredConversation()

    // ── Audio ─────────────────────────────────────────────────────────────
    private let audioEngine   = AVAudioEngine()
    private var nativeSampleRate: Double = 44_100
    private var rawSpeechBuffer: [Float] = []

    // ── VAD ───────────────────────────────────────────────────────────────
    private var isSpeechActive  = false
    private var silenceStart:   Date?
    private var speechStart:    Date?
    private let silenceDB:      Float = -42        // threshold dB
    private let silenceDur:     TimeInterval = 1.2 // silence → commit
    private let minSpeechDur:   TimeInterval = 0.4 // ignore clips shorter than this

    override init() { super.init() }

    // MARK: - Boot

    func boot() async {
        statusLabel = "Requesting permissions…"
        guard await requestPermissions() else { return }

        statusLabel = "Loading Whisper model (first run downloads ~500 MB)…"
        log("Starting Whisper setup")
        await whisperEngine.setup()

        switch whisperEngine.state {
        case .ready:
            log("Whisper ready")
        case .failed(let e):
            log("Whisper failed: \(e)")
            await appleEngine.setup()
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
        store.upsert(currentConversation)
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        rawSpeechBuffer = []
        isSpeechActive  = false
        silenceStart    = nil
        speechStart     = nil
        isListening     = false
        audioLevel      = 0
        liveTranscript  = ""
        try? AVAudioSession.sharedInstance()
             .setActive(false, options: .notifyOthersOnDeactivation)
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

        // Tap at native rate; resample to 16 kHz on main actor before Whisper
        input.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) {
            [weak self] buf, _ in
            guard let self else { return }

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
                    }
                }
            }
        }
    }

    private func commitChunk() {
        guard !rawSpeechBuffer.isEmpty else { return }
        let raw = rawSpeechBuffer
        resetBuffer()

        guard !isProcessing else { log("Dropped chunk (busy)"); return }

        let srcRate = nativeSampleRate
        Task { [weak self] in
            guard let self else { return }
            // Resample to 16 kHz (Whisper requirement) — linear interpolation
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
        defer { isProcessing = false }

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
        debugLog.append("[\(ts)] \(msg)")
        if debugLog.count > 40 { debugLog.removeFirst() }
        print("RT: \(msg)")
    }
}
```

---

## `Sources/RealtimeTranslator/ConversationStore.swift`  *(UPDATED)*

```swift
import Foundation
import Observation

// MARK: - Models

struct StoredConversation: Codable, Identifiable {
    var id       = UUID()
    var date     = Date()
    var messages: [StoredMessage] = []

    var isEmpty: Bool { messages.isEmpty }

    var title: String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    var preview: String {
        messages.first.map { "🇬🇧 \($0.english)" } ?? ""
    }
}

struct StoredMessage: Codable, Identifiable {
    var id        = UUID()
    var english:    String          // translated English output
    var engine:     String          // "whisper" | "apple" | "apple-fallback"
    var timestamp   = Date()
}

// MARK: - Store

@Observable
final class ConversationStore {

    var conversations: [StoredConversation] = []

    private let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("rt_conversations_v2.json")
    }()

    init() { load() }

    func upsert(_ conv: StoredConversation) {
        guard !conv.isEmpty else { return }
        if let idx = conversations.firstIndex(where: { $0.id == conv.id }) {
            conversations[idx] = conv
        } else {
            conversations.insert(conv, at: 0)
        }
        persist()
    }

    func delete(at offsets: IndexSet) {
        conversations.remove(atOffsets: offsets)
        persist()
    }

    func clearAll() {
        conversations.removeAll()
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        conversations = (try? JSONDecoder().decode([StoredConversation].self, from: data)) ?? []
    }

    private func persist() {
        try? JSONEncoder().encode(conversations).write(to: fileURL, options: .atomic)
    }
}
```

---

## `Sources/RealtimeTranslator/ContentView.swift`  *(FULL REWRITE — Phase 5)*

```swift
import SwiftUI
import Translation

struct ContentView: View {

    @State private var engine      = TranslatorEngine()
    @State private var showHistory = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color(white: 0.06).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                outputPanel
                micBar
            }
        }
        // Apple engine translation session hook (Phase 6)
        .translationTask(engine.appleEngine.translationConfig) { session in
            await engine.appleEngine.handleSession(session)
        }
        .sheet(isPresented: $showHistory)  { HistoryView(store: engine.store) }
        .sheet(isPresented: $showSettings) {
            SettingsView(engine: engine, isPresented: $showSettings)
        }
        .overlay(alignment: .bottom) { debugOverlay }
        .task { await engine.boot() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("🇹🇭 → 🇬🇧")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                Text("Thai · English Live")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
            Button { showHistory = true } label: {
                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .iconStyle()
            }
            Button { showSettings = true } label: {
                Image(systemName: "gear")
                    .iconStyle()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(white: 0.11))
    }

    // MARK: - Output panel

    private var outputPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(engine.messages.enumerated()), id: \.element.id) { i, msg in
                        MessageBubble(msg: msg)
                            .id(i)
                    }
                    // Live "typing" indicator
                    if !engine.liveTranscript.isEmpty {
                        Text(engine.liveTranscript)
                            .font(.body.italic())
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.horizontal, 14)
                            .id("live")
                    }
                    if engine.messages.isEmpty && engine.liveTranscript.isEmpty && engine.isReady {
                        emptyState
                    }
                }
                .padding(.vertical, 12)
            }
            .onChange(of: engine.messages.count) {
                withAnimation { proxy.scrollTo(engine.messages.count - 1, anchor: .bottom) }
            }
            .onChange(of: engine.liveTranscript) {
                withAnimation { proxy.scrollTo("live", anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .center) {
            if !engine.isReady { loadingOverlay }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.1))
            Text("Tap the mic and speak Thai.\nTranslation appears here in English.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.2))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var loadingOverlay: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white.opacity(0.6))
                .scaleEffect(1.3)
            Text(engine.statusLabel.isEmpty ? "Preparing…" : engine.statusLabel)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    // MARK: - Mic bar

    private var micBar: some View {
        VStack(spacing: 8) {
            if let err = engine.errorMessage {
                Text(err)
                    .font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }

            // Waveform
            if engine.isListening {
                WaveformView(level: engine.audioLevel, color: .cyan)
                    .frame(maxWidth: 180, maxHeight: 18)
            }

            // Big mic button
            Button(action: engine.toggleListening) {
                ZStack {
                    Circle()
                        .fill(engine.isListening
                              ? Color.cyan.opacity(0.2)
                              : Color.white.opacity(0.08))
                        .frame(width: 76, height: 76)
                        .overlay(
                            Circle().stroke(
                                engine.isListening
                                    ? Color.cyan.opacity(0.8)
                                    : Color.white.opacity(0.15),
                                lineWidth: engine.isListening ? 2.5 : 1
                            )
                        )
                    if engine.isListening {
                        Circle()
                            .stroke(Color.cyan.opacity(0.3), lineWidth: 3)
                            .frame(width: 96, height: 96)
                            .scaleEffect(1 + CGFloat(engine.audioLevel) * 0.22)
                            .animation(.easeOut(duration: 0.1), value: engine.audioLevel)
                    }
                    Image(systemName: engine.isListening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(engine.isListening ? .cyan : .white.opacity(0.7))
                }
            }
            .disabled(!engine.isReady)
            .opacity(engine.isReady ? 1 : 0.3)
            .buttonStyle(.plain)

            // Engine badge
            engineBadge
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.11))
    }

    private var engineBadge: some View {
        Group {
            switch engine.whisperEngine.state {
            case .ready, .inferring:
                Label("Whisper · ANE", systemImage: "brain.head.profile")
                    .foregroundStyle(.cyan.opacity(0.6))
            case .loading:
                Label("Loading model…", systemImage: "arrow.down.circle")
                    .foregroundStyle(.orange.opacity(0.6))
            case .failed:
                if engine.appleEngine.isAvailable {
                    Label("Apple Translate", systemImage: "apple.logo")
                        .foregroundStyle(.yellow.opacity(0.6))
                } else {
                    Label("No engine", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red.opacity(0.7))
                }
            default: EmptyView()
            }
        }
        .font(.caption2)
    }

    // MARK: - Debug overlay

    private var debugOverlay: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(engine.debugLog.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.green)
                            .id(i)
                    }
                }
                .padding(6)
            }
            .frame(maxWidth: .infinity, maxHeight: 110)
            .background(Color.black.opacity(0.8))
            .onChange(of: engine.debugLog.count) {
                proxy.scrollTo(engine.debugLog.count - 1, anchor: .bottom)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - MessageBubble

private struct MessageBubble: View {
    let msg: TranslationMessage

    private var engineIcon: String {
        switch msg.engine {
        case "whisper":         return "🧠"
        case "apple":           return "🍎"
        case "apple-fallback":  return "🍎↩"
        default:                return "•"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(engineIcon)
                .font(.caption)
                .padding(.top, 2)
            Text(msg.english)
                .font(.body)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

// MARK: - WaveformView

struct WaveformView: View {
    let level: Float
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<7, id: \.self) { i in
                let shape: Float = [0.3, 0.6, 0.85, 1.0, 0.85, 0.6, 0.3][i]
                let h = 3 + CGFloat(level * shape) * 15
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 4, height: max(3, h))
                    .animation(.easeInOut(duration: 0.1).delay(Double(i) * 0.03), value: level)
            }
        }
    }
}

// MARK: - Helpers

private extension Image {
    func iconStyle() -> some View {
        self.font(.system(size: 17))
            .foregroundStyle(.white.opacity(0.45))
            .frame(width: 40, height: 40)
    }
}

// MARK: - History Views (unchanged structure, adapted for new model)

struct HistoryView: View {
    let store: ConversationStore
    @State private var selected: StoredConversation?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.07).ignoresSafeArea()
                if store.conversations.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 44))
                            .foregroundStyle(.white.opacity(0.12))
                        Text("No conversations saved yet.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.3))
                    }
                } else {
                    List {
                        ForEach(store.conversations) { conv in
                            Button { selected = conv } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(conv.title)
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.white)
                                    Text(conv.preview)
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.45))
                                        .lineLimit(1)
                                    Text("\(conv.messages.count) phrases")
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.25))
                                }
                                .padding(.vertical, 4)
                            }
                            .listRowBackground(Color(white: 0.12))
                        }
                        .onDelete { store.delete(at: $0) }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }.foregroundStyle(.white)
                }
            }
            .sheet(item: $selected) { ConversationDetailView(conversation: $0) }
        }
    }
}

struct ConversationDetailView: View {
    let conversation: StoredConversation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.07).ignoresSafeArea()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(conversation.messages) { msg in
                            HStack(alignment: .top, spacing: 12) {
                                Text(msg.engine.hasPrefix("apple") ? "🍎" : "🧠")
                                    .font(.caption)
                                Text(msg.english)
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                                Spacer()
                                Text(msg.timestamp, style: .time)
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.3))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            Divider().background(.white.opacity(0.06)).padding(.leading, 16)
                        }
                    }
                }
            }
            .navigationTitle(conversation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }.foregroundStyle(.white)
                }
            }
        }
    }
}

#Preview { ContentView() }
```

---

## `Sources/RealtimeTranslator/SettingsView.swift`  *(NEW — Phase 5.3)*

```swift
import SwiftUI

struct SettingsView: View {
    @Bindable var engine: TranslatorEngine
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.07).ignoresSafeArea()
                Form {
                    // ── Engine selector ───────────────────────────────────
                    Section {
                        Picker("Preferred engine", selection: $engine.enginePreference) {
                            ForEach(TranslationEngineType.allCases) { t in
                                Text(t.rawValue).tag(t)
                            }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color(white: 0.14))
                    } header: {
                        Text("Translation Engine")
                            .foregroundStyle(.white.opacity(0.5))
                    } footer: {
                        Text("Whisper (ANE) runs fully on-device via the Apple Neural Engine. "
                           + "Apple Translate uses SFSpeechRecognizer + the system Translation framework.")
                            .foregroundStyle(.white.opacity(0.3))
                    }

                    // ── Whisper model status ──────────────────────────────
                    Section("Whisper Model") {
                        whisperStatusRow
                        if case .failed = engine.whisperEngine.state {
                            Button("Retry download") {
                                Task { await engine.whisperEngine.setup() }
                            }
                            .foregroundStyle(.cyan)
                        }
                    }
                    .listRowBackground(Color(white: 0.14))

                    // ── Apple engine status ───────────────────────────────
                    Section("Apple Translate Fallback") {
                        HStack {
                            Text("Thai ASR (SFSpeechRecognizer)")
                            Spacer()
                            Text(engine.appleEngine.isAvailable ? "✓ Available" : "✗ Unavailable")
                                .font(.caption)
                                .foregroundStyle(engine.appleEngine.isAvailable
                                                 ? .green : .red.opacity(0.7))
                        }
                    }
                    .listRowBackground(Color(white: 0.14))

                    // ── Danger zone ───────────────────────────────────────
                    Section {
                        Button(role: .destructive) {
                            engine.store.clearAll()
                        } label: {
                            Label("Clear conversation history", systemImage: "trash")
                        }
                    }
                    .listRowBackground(Color(white: 0.14))
                }
                .scrollContentBackground(.hidden)
                .foregroundStyle(.white)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isPresented = false }.foregroundStyle(.white)
                }
            }
        }
    }

    @ViewBuilder
    private var whisperStatusRow: some View {
        HStack {
            Text("openai_whisper-small")
            Spacer()
            switch engine.whisperEngine.state {
            case .idle:
                Text("Not started")
                    .font(.caption).foregroundStyle(.white.opacity(0.35))
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.8)
                    Text("Loading…").font(.caption).foregroundStyle(.orange)
                }
            case .ready:
                Text("✓ Ready").font(.caption).foregroundStyle(.green)
            case .inferring:
                Text("⟳ Inferring").font(.caption).foregroundStyle(.cyan)
            case .failed(let e):
                Text("✗ " + (e.prefix(30))).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
```

---

## `Sources/RealtimeTranslator/RealtimeTranslatorApp.swift`

*(no changes required)*

---

## Deletion checklist

| Action | File |
|--------|------|
| **DELETE** | `Sources/RealtimeTranslator/AppleTranslator.swift` |

The `project.yml` `excludes:` block handles it if the file lingers, but removing it keeps the repo clean.

---

## Architecture summary

```
Thai Audio (mic)
       │  AVAudioEngine — native sample rate
       ▼
   VAD (RMS / dB gate)          ← accumulates raw PCM during speech
       │  silence detected
       ▼
resampleLinear(44 kHz → 16 kHz)
       │
       ├──[preference = Whisper / Auto + model ready]──────────────────►
       │                                                    WhisperEngine
       │                                           whisper.cpp + CoreML/ANE
       │                                         task=translate, language=th
       │                                                    ▼ English text
       │
       └──[preference = Apple / Whisper failed]────────────────────────►
                                                  AppleTranslationEngine
                                              SFSpeechRecognizer(th-TH)
                                                          ▼ Thai text
                                              Translation framework (th→en)
                                                          ▼ English text
                                                               │
                                                    TranslatorEngine
                                                  messages[] / ConversationStore
                                                          ▼
                                                    ContentView (SwiftUI)
```
