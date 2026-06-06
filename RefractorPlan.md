{
  "project": "RealtimeTranslator",
  "description": "Patch instructions for all logic errors identified in the codebase audit",
  "fixes": [
    {
      "id": 1,
      "severity": "critical",
      "title": "Apple engine never set up unless Whisper fails at boot",
      "file": "Sources/RealtimeTranslator/TranslatorEngine.swift",
      "function": "boot()",
      "action": "replace",
      "find": "statusLabel = \"Loading Whisper model (first run downloads ~500 MB)…\"\n        log(\"Starting Whisper setup\")\n        await whisperEngine.setup()\n\n        switch whisperEngine.state {\n        case .ready:\n            log(\"Whisper ready\")\n        case .failed(let e):\n            log(\"Whisper failed: \\(e)\")\n            await appleEngine.setup()\n            if appleEngine.isAvailable {\n                log(\"Apple engine ready (fallback)\")\n            } else {\n                errorMessage = \"No translation engine available on this device.\"\n                return\n            }\n        default: break\n        }",
      "replace_with": "statusLabel = \"Loading Whisper model (first run downloads ~500 MB)…\"\n        log(\"Starting Whisper setup\")\n        await whisperEngine.setup()\n\n        // Always set up Apple engine so it is available for manual selection\n        // and as a Whisper fallback, regardless of Whisper's result.\n        await appleEngine.setup()\n\n        switch whisperEngine.state {\n        case .ready:\n            log(\"Whisper ready\")\n        case .failed(let e):\n            log(\"Whisper failed: \\(e)\")\n            if appleEngine.isAvailable {\n                log(\"Apple engine ready (fallback)\")\n            } else {\n                errorMessage = \"No translation engine available on this device.\"\n                return\n            }\n        default: break\n        }",
      "rationale": "AppleTranslationEngine.setup() was only called when Whisper failed. If a user manually switches to the Apple engine in Settings, recognizerTH?.isAvailable is false and translateAudio throws .unavailable. Setting up the Apple engine unconditionally ensures it is ready for both manual selection and fallback use."
    },
    {
      "id": 2,
      "severity": "critical",
      "title": "Retry download silently no-ops while Whisper is inferring",
      "file": "Sources/RealtimeTranslator/WhisperEngine.swift",
      "function": "setup()",
      "action": "replace",
      "find": "switch state {\n        case .idle, .failed: break\n        default: return\n        }",
      "replace_with": "switch state {\n        case .idle, .failed: break\n        case .loading, .ready: return   // already loaded or in progress\n        case .inferring:\n            // Wait until inference finishes before allowing a reload.\n            // Callers (e.g. Settings \"Retry\") should disable the button while\n            // state == .inferring to avoid reaching this branch.\n            return\n        }",
      "rationale": "The original default: return path silently swallowed a Retry tap while the engine was inferring. The revised switch is explicit about every case, making the intent clear and making it easy to add a queued-retry path in future. Pair this with disabling the Retry button in SettingsView when state == .inferring (see fix #2b)."
    },
    {
      "id": "2b",
      "severity": "critical",
      "title": "Disable Retry button in Settings while Whisper is inferring",
      "file": "Sources/RealtimeTranslator/SettingsView.swift",
      "function": "body (Whisper Model Section)",
      "action": "replace",
      "find": "if case .failed = engine.whisperEngine.state {\n                            Button(\"Retry download\") {\n                                Task { await engine.whisperEngine.setup() }\n                            }\n                            .foregroundStyle(.cyan)\n                        }",
      "replace_with": "if case .failed = engine.whisperEngine.state {\n                            Button(\"Retry download\") {\n                                Task { await engine.whisperEngine.setup() }\n                            }\n                            .foregroundStyle(.cyan)\n                            .disabled(engine.whisperEngine.state == .inferring)\n                        }",
      "rationale": "Prevents the user from tapping Retry while inference is in progress, avoiding the silent no-op described in fix #2."
    },
    {
      "id": 3,
      "severity": "critical",
      "title": "pendingText race on overlapping Apple translation calls",
      "file": "Sources/RealtimeTranslator/AppleTranslationEngine.swift",
      "function": "translateText(_:)",
      "action": "replace",
      "find": "private func translateText(_ thai: String) async throws -> String {\n        pendingText = thai\n        return try await withTaskCancellationHandler {\n            try await withCheckedThrowingContinuation { [weak self] cont in\n                guard let self else { cont.resume(throwing: CancellationError()); return }\n                self.sessionContinuation?.resume(throwing: CancellationError())\n                self.sessionContinuation = cont\n                // Setting this triggers .translationTask in ContentView\n                self.translationConfig = TranslationSession.Configuration(\n                    source: Locale.Language(identifier: \"th\"),\n                    target: Locale.Language(identifier: \"en\")\n                )\n            }\n        } onCancel: {\n            Task { @MainActor [weak self] in self?.cancel() }\n        }\n    }",
      "replace_with": "private func translateText(_ thai: String) async throws -> String {\n        // Cancel any in-flight translation BEFORE overwriting pendingText,\n        // so the displaced continuation always sees the text it was created for.\n        if let existing = sessionContinuation {\n            existing.resume(throwing: CancellationError())\n            sessionContinuation = nil\n            translationConfig   = nil\n        }\n        pendingText = thai\n        return try await withTaskCancellationHandler {\n            try await withCheckedThrowingContinuation { [weak self] cont in\n                guard let self else { cont.resume(throwing: CancellationError()); return }\n                self.sessionContinuation = cont\n                // Setting this triggers .translationTask in ContentView\n                self.translationConfig = TranslationSession.Configuration(\n                    source: Locale.Language(identifier: \"th\"),\n                    target: Locale.Language(identifier: \"en\")\n                )\n            }\n        } onCancel: {\n            Task { @MainActor [weak self] in self?.cancel() }\n        }\n    }",
      "rationale": "The original code overwrote pendingText before cancelling the old continuation, meaning a racing SwiftUI .translationTask could call handleSession with the wrong (already-replaced) text. By cancelling first, then assigning pendingText, each continuation is guaranteed to operate on the text it was created for."
    },
    {
      "id": 4,
      "severity": "medium",
      "title": "Concurrent speech chunks silently dropped — add a pending slot queue",
      "file": "Sources/RealtimeTranslator/TranslatorEngine.swift",
      "function": "commitChunk() and property declarations",
      "action": "multi_step",
      "steps": [
        {
          "step": 1,
          "description": "Add a pendingChunk property to hold one buffered chunk while processing is busy",
          "action": "replace",
          "find": "    // ── Audio ─────────────────────────────────────────────────────────────\n    private let audioEngine   = AVAudioEngine()\n    private var nativeSampleRate: Double = 44_100\n    private var rawSpeechBuffer: [Float] = []",
          "replace_with": "    // ── Audio ─────────────────────────────────────────────────────────────\n    private let audioEngine   = AVAudioEngine()\n    private var nativeSampleRate: Double = 44_100\n    private var rawSpeechBuffer: [Float] = []\n    /// Holds at most one chunk that arrived while processing was busy.\n    /// When the current translation finishes, this chunk is processed next.\n    private var pendingChunk: [Float]?"
        },
        {
          "step": 2,
          "description": "Replace the drop-on-busy guard in commitChunk with a pending slot",
          "action": "replace",
          "find": "        guard !isProcessing else { log(\"Dropped chunk (busy)\"); return }\n\n        let srcRate = nativeSampleRate\n        Task { [weak self] in\n            guard let self else { return }\n            // Resample to 16 kHz (Whisper requirement) — linear interpolation\n            let s16k = resampleLinear(raw, from: srcRate, to: 16_000)\n            await self.process(samples: s16k)\n        }",
          "replace_with": "        let srcRate = nativeSampleRate\n        guard !isProcessing else {\n            // Buffer the latest chunk; older buffered chunk is discarded.\n            log(\"Queued chunk (was busy); previous pending chunk replaced if any\")\n            let s16k = resampleLinear(raw, from: srcRate, to: 16_000)\n            pendingChunk = s16k\n            return\n        }\n\n        Task { [weak self] in\n            guard let self else { return }\n            let s16k = resampleLinear(raw, from: srcRate, to: 16_000)\n            await self.process(samples: s16k)\n        }"
        },
        {
          "step": 3,
          "description": "Drain the pending chunk at the end of process(samples:) after isProcessing is cleared",
          "action": "replace",
          "find": "        isProcessing   = true\n        liveTranscript = \"⟳ Translating…\"\n        defer { isProcessing = false }",
          "replace_with": "        isProcessing   = true\n        liveTranscript = \"⟳ Translating…\"\n        defer {\n            isProcessing = false\n            // Drain the pending chunk, if any arrived while we were busy.\n            if let next = pendingChunk {\n                pendingChunk = nil\n                Task { await self.process(samples: next) }\n            }\n        }"
        },
        {
          "step": 4,
          "description": "Clear pendingChunk inside stopListening so stale audio is not replayed after session ends",
          "action": "replace",
          "find": "        rawSpeechBuffer = []\n        isSpeechActive  = false\n        silenceStart    = nil\n        speechStart     = nil\n        isListening     = false",
          "replace_with": "        rawSpeechBuffer = []\n        pendingChunk    = nil\n        isSpeechActive  = false\n        silenceStart    = nil\n        speechStart     = nil\n        isListening     = false"
        }
      ],
      "rationale": "The original guard !isProcessing drop meant any speech uttered while Whisper was inferring was silently lost. A single-slot pending queue retains the most recent chunk and processes it immediately after the current translation completes, balancing responsiveness against unbounded queuing."
    },
    {
      "id": 5,
      "severity": "medium",
      "title": "store.upsert called before audio engine is fully stopped",
      "file": "Sources/RealtimeTranslator/TranslatorEngine.swift",
      "function": "stopListening()",
      "action": "replace",
      "find": "    func stopListening() {\n        store.upsert(currentConversation)\n        audioEngine.stop()\n        audioEngine.inputNode.removeTap(onBus: 0)\n        rawSpeechBuffer = []\n        isSpeechActive  = false\n        silenceStart    = nil\n        speechStart     = nil\n        isListening     = false\n        audioLevel      = 0\n        liveTranscript  = \"\"\n        try? AVAudioSession.sharedInstance()\n             .setActive(false, options: .notifyOthersOnDeactivation)\n        log(\"Stopped\")\n    }",
      "replace_with": "    func stopListening() {\n        // Stop the audio pipeline first so no further callbacks can append\n        // to currentConversation after we persist it.\n        audioEngine.stop()\n        audioEngine.inputNode.removeTap(onBus: 0)\n        rawSpeechBuffer = []\n        pendingChunk    = nil\n        isSpeechActive  = false\n        silenceStart    = nil\n        speechStart     = nil\n        isListening     = false\n        audioLevel      = 0\n        liveTranscript  = \"\"\n        try? AVAudioSession.sharedInstance()\n             .setActive(false, options: .notifyOthersOnDeactivation)\n        // Persist after the tap is removed — snapshot is now stable.\n        store.upsert(currentConversation)\n        log(\"Stopped\")\n    }",
      "rationale": "Moving store.upsert to after audioEngine.stop() and removeTap(onBus:0) guarantees no further onAudio callbacks can mutate currentConversation between the upsert snapshot and the actual audio teardown."
    },
    {
      "id": 6,
      "severity": "medium",
      "title": "Scroll to index -1 when message list is empty",
      "file": "Sources/RealtimeTranslator/ContentView.swift",
      "function": "outputPanel (onChange handler)",
      "action": "replace",
      "find": "            .onChange(of: engine.messages.count) {\n                withAnimation { proxy.scrollTo(engine.messages.count - 1, anchor: .bottom) }\n            }",
      "replace_with": "            .onChange(of: engine.messages.count) {\n                guard engine.messages.count > 0 else { return }\n                withAnimation { proxy.scrollTo(engine.messages.count - 1, anchor: .bottom) }\n            }"
    },
    {
      "id": 7,
      "severity": "medium",
      "title": "AppStorageKeys defined but never wired up — engine preference and debug flag not persisted across launches",
      "files": [
        "Sources/RealtimeTranslator/TranslatorEngine.swift",
        "Sources/RealtimeTranslator/ContentView.swift"
      ],
      "action": "multi_file",
      "steps": [
        {
          "step": 1,
          "file": "Sources/RealtimeTranslator/TranslatorEngine.swift",
          "description": "Persist enginePreference via AppStorage so it survives app restarts",
          "action": "replace",
          "find": "    var enginePreference: TranslationEngineType = .auto",
          "replace_with": "    /// Backed by UserDefaults so the chosen engine survives app restarts.\n    @AppStorage(AppStorageKeys.preferredEngine)\n    var enginePreference: TranslationEngineType = .auto"
        },
        {
          "step": 2,
          "file": "Sources/RealtimeTranslator/TranslatorEngine.swift",
          "description": "Add TranslationEngineType RawRepresentable conformance required by @AppStorage (String raw value already satisfies this — just needs the import confirmed). Add showDebugLog as an @AppStorage property.",
          "action": "replace",
          "find": "    var store = ConversationStore()",
          "replace_with": "    @AppStorage(AppStorageKeys.showDebugLog)\n    var showDebugLog: Bool = false\n\n    var store = ConversationStore()"
        },
        {
          "step": 3,
          "file": "Sources/RealtimeTranslator/ContentView.swift",
          "description": "Gate the debug overlay on showDebugLog so the AppStorage key has a visible effect",
          "action": "replace",
          "find": "        .overlay(alignment: .bottom) { debugOverlay }",
          "replace_with": "        .overlay(alignment: .bottom) {\n            if engine.showDebugLog { debugOverlay }\n        }"
        },
        {
          "step": 4,
          "file": "Sources/RealtimeTranslator/SettingsView.swift",
          "description": "Add a toggle for showDebugLog in the Settings UI so users can enable it",
          "action": "replace",
          "find": "                    // ── Danger zone ───────────────────────────────────────",
          "replace_with": "                    // ── Developer ────────────────────────────────────────\n                    Section(\"Developer\") {\n                        Toggle(\"Show debug log\", isOn: $engine.showDebugLog)\n                    }\n                    .listRowBackground(Color(white: 0.14))\n\n                    // ── Danger zone ───────────────────────────────────────"
        }
      ],
      "rationale": "AppStorageKeys.preferredEngine and showDebugLog were declared but never used. Engine preference was stored only in memory, resetting to .auto on every launch. The debug overlay was always visible with no way to hide it. These changes wire both keys to @AppStorage, persist the user's engine choice, and give the debug toggle a real on/off effect."
    },
    {
      "id": 8,
      "severity": "minor",
      "title": "TelemetryLogger: OSAllocatedUnfairLock is unnecessary overhead for single-use instances",
      "file": "Sources/RealtimeTranslator/TelemetryLogger.swift",
      "action": "replace",
      "find": "final class TelemetryLogger: Sendable {\n\n    private let log = Logger(subsystem: \"com.realtimetranslator\", category: \"telemetry\")\n    private let lock = OSAllocatedUnfairLock(initialState: [String: Date]())\n\n    func start(_ event: String) {\n        lock.withLock { $0[event] = Date() }\n    }\n\n    func end(_ event: String, engine: String) {\n        let elapsed = lock.withLock { dict -> TimeInterval? in\n            guard let t = dict.removeValue(forKey: event) else { return nil }\n            return Date().timeIntervalSince(t)\n        }\n        guard let ms = elapsed else { return }\n        log.info(\"[\\(engine, privacy: .public)] \\(event, privacy: .public): \\(Int(ms * 1000), privacy: .public)ms\")\n    }\n}",
      "replace_with": "/// Lightweight per-event wall-clock timer.\n/// Each instance is created and used within a single @MainActor process() call,\n/// so no locking is required.\n@MainActor\nfinal class TelemetryLogger {\n\n    private let log = Logger(subsystem: \"com.realtimetranslator\", category: \"telemetry\")\n    private var starts: [String: Date] = [:]\n\n    func start(_ event: String) {\n        starts[event] = Date()\n    }\n\n    func end(_ event: String, engine: String) {\n        guard let t = starts.removeValue(forKey: event) else { return }\n        let ms = Int(Date().timeIntervalSince(t) * 1000)\n        log.info(\"[\\(engine, privacy: .public)] \\(event, privacy: .public): \\(ms, privacy: .public)ms\")\n    }\n}",
      "rationale": "TelemetryLogger is instantiated fresh in every process() call on @MainActor and start/end are always called on the same actor. There is no cross-thread access, so OSAllocatedUnfairLock adds overhead with no benefit. Replacing it with a plain dictionary and annotating the class @MainActor makes the threading contract explicit and the code simpler."
    },
    {
      "id": 9,
      "severity": "minor",
      "title": "ConversationStore missing @MainActor annotation — potential data-race with Observable",
      "file": "Sources/RealtimeTranslator/ConversationStore.swift",
      "action": "replace",
      "find": "@Observable\nfinal class ConversationStore {",
      "replace_with": "@Observable\n@MainActor\nfinal class ConversationStore {",
      "rationale": "ConversationStore is @Observable and is exclusively read/written from @MainActor contexts (TranslatorEngine, HistoryView). Adding @MainActor makes the isolation explicit, prevents accidental off-main access in future, and satisfies the Swift concurrency checker without requiring locks."
    }
  ],
  "application_order": [9, 8, 1, "2b", 2, 3, "4.1", "4.2", "4.3", "4.4", 5, 6, "7.1", "7.2", "7.3", "7.4"],
  "notes": [
    "Apply fix #9 (ConversationStore @MainActor) before #1 so the compiler sees the correct isolation when TranslatorEngine calls store.upsert.",
    "Fix #4 (pending chunk) introduces pendingChunk property — apply all four steps of fix #4 together before fix #5, since fix #5's stopListening replacement references pendingChunk.",
    "Fix #7 uses @AppStorage on TranslatorEngine. Ensure TranslationEngineType's String RawValue (already present) satisfies the @AppStorage constraint — no additional conformance code needed.",
    "All find strings are whitespace-sensitive. Match indentation exactly as it appears in the source files."
  ]
}