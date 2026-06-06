import Foundation
import AVFoundation
import Speech
import Observation

// MARK: - Models

enum ActiveMic { case none, english, spanish }

struct TranslationMessage: Identifiable {
    let id        = UUID()
    let english:    String
    let spanish:    String
    let sourceLang: String   // "en" | "es"  → determina el color en la UI
    let timestamp = Date()
}

// MARK: - Engine

@Observable
@MainActor
final class TranslatorEngine: NSObject {

    // UI state
    var activeMic:   ActiveMic = .none
    var isSpeaking   = false
    var isReady      = false
    var audioLevel:  Float = 0
    var statusLabel  = "Solicitando permisos..."
    var debugLog:    [String] = []

    // Paneles en vivo
    var liveEnglish  = ""
    var liveSpanish  = ""
    var messages:    [TranslationMessage] = []
    var errorMessage: String?

    // SFSpeechRecognizer — uno por idioma
    private let recognizerEN = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    private let recognizerES = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))!
    private var activeRequest: SFSpeechAudioBufferRecognitionRequest?
    private var activeTask:    SFSpeechRecognitionTask?

    // Apple Translation
    let translator = AppleTranslator()

    // Historia
    var store = ConversationStore()
    private var currentConversation = StoredConversation()

    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()

    // VAD + debounce
    private var silenceStart: Date? = nil
    private var debounceTask: Task<Void, Never>?
    private var blockMic      = false
    private var isTranslating = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Boot

    func boot() async {
        let granted = await requestPermissions()
        guard granted else { return }
        isReady     = true
        statusLabel = ""
        log("Listo")
    }

    private func log(_ msg: String) {
        let ts = Date().formatted(.dateTime.hour().minute().second())
        debugLog.append("[\(ts)] \(msg)")
        if debugLog.count > 30 { debugLog.removeFirst() }
        print("DEBUG: \(msg)")
    }

    // MARK: - Permissions

    private func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        guard speech else { errorMessage = "Permiso de reconocimiento de voz denegado."; return false }
        let mic = await AVAudioApplication.requestRecordPermission()
        guard mic else { errorMessage = "Permiso de micrófono denegado."; return false }
        return true
    }

    // MARK: - Mic buttons

    func tapEnglishMic() {
        if activeMic == .english { stopListening(); return }
        stopListening()
        activeMic = .english
        tryStart()
    }

    func tapSpanishMic() {
        if activeMic == .spanish { stopListening(); return }
        stopListening()
        activeMic = .spanish
        tryStart()
    }

    private func tryStart() {
        do { try startAudio() }
        catch { errorMessage = error.localizedDescription }
    }

    // MARK: - Audio engine

    private func startAudio() throws {
        liveEnglish = ""
        liveSpanish = ""
        currentConversation = StoredConversation()

        let av = AVAudioSession.sharedInstance()
        try av.setCategory(.playAndRecord, mode: .voiceChat,
                           options: [.allowBluetooth, .allowBluetoothA2DP])
        try av.setActive(true)
        if #available(iOS 18.2, *), av.isEchoCancelledInputAvailable {
            try av.setPrefersEchoCancelledInput(true)
        }

        let input  = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            guard let self, !self.blockMic else { return }
            self.activeRequest?.append(buf)
            self.updateLevel(buf)
        }

        audioEngine.prepare()
        try audioEngine.start()
        launchRecognitionTask()
    }

    func stopListening() {
        debounceTask?.cancel()
        translator.cancel()
        if activeMic != .none { store.upsert(currentConversation) }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        activeRequest?.endAudio(); activeTask?.cancel()
        activeRequest = nil; activeTask = nil
        activeMic    = .none
        blockMic     = false
        audioLevel   = 0
        silenceStart = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - SFSpeechRecognizer (ambos idiomas)

    private func launchRecognitionTask() {
        let recognizer = activeMic == .english ? recognizerEN : recognizerES
        guard recognizer.isAvailable else {
            log("Reconocedor no disponible")
            return
        }

        activeRequest = SFSpeechAudioBufferRecognitionRequest()
        activeRequest?.shouldReportPartialResults = true

        activeTask = recognizer.recognitionTask(with: activeRequest!) { [weak self] result, error in
            // Extraer valores primitivos ANTES de cruzar al actor principal
            let errorCode = (error as NSError?)?.code
            let text      = result?.bestTranscription.formattedString ?? ""
            let isFinal   = result?.isFinal ?? false

            Task { @MainActor [weak self] in
                guard let self else { return }

                if errorCode == 1110 {
                    self.restartRecognitionTask()
                    return
                }
                guard !text.isEmpty else { return }

                self.updateLiveText(text)
                self.debounceTask?.cancel()

                if isFinal {
                    self.debounceTask = Task { @MainActor [weak self] in
                        await self?.handleFinalText(text)
                    }
                } else {
                    self.debounceTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(1500))
                        guard !Task.isCancelled, let self else { return }
                        let silence = self.silenceStart.map { Date().timeIntervalSince($0) } ?? 0
                        if silence >= 1.2 { await self.handleFinalText(text) }
                    }
                }
            }
        }
    }

    private func restartRecognitionTask() {
        guard activeMic != .none else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        activeRequest?.endAudio(); activeTask?.cancel()
        activeRequest = nil; activeTask = nil

        Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard self.activeMic != .none else { return }
            let input  = self.audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
                guard let self, !self.blockMic else { return }
                self.activeRequest?.append(buf)
                self.updateLevel(buf)
            }
            self.launchRecognitionTask()
        }
    }

    // MARK: - Traducción

    private func handleFinalText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isTranslating, activeMic != .none, !trimmed.isEmpty else { return }

        isTranslating = true
        defer { isTranslating = false }

        let isEN = activeMic == .english
        let (from, to, voice, toSpeaker) = isEN
            ? ("en", "es", "es-ES", false)
            : ("es", "en", "en-US", true)

        log("Traduciendo (\(from)→\(to)): \"\(trimmed.prefix(40))\"")

        do {
            let translated = try await translator.translate(trimmed, from: from, to: to)
            log("OK: \"\(translated.prefix(40))\"")

            let src = isEN ? "en" : "es"
            messages.append(TranslationMessage(
                english:    isEN ? trimmed : translated,
                spanish:    isEN ? translated : trimmed,
                sourceLang: src
            ))
            currentConversation.messages.append(
                StoredMessage(original: trimmed, translated: translated, sourceLang: src)
            )
            store.upsert(currentConversation)
            liveEnglish = ""
            liveSpanish = ""
            speak(translated, voice: voice, toSpeaker: toSpeaker)
            // Reiniciar sesión para que la siguiente frase empiece desde cero
            restartRecognitionTask()
        } catch {
            log("ERROR traduccion: \(error.localizedDescription) | texto: \"\(trimmed.prefix(30))\"")
        }
    }

    // MARK: - Audio level / VAD

    private func updateLiveText(_ text: String) {
        if activeMic == .english { liveEnglish = text }
        else                      { liveSpanish = text }
    }

    private func updateLevel(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(n))
        let db  = 20 * log10(max(rms, 1e-10))
        let lvl = Float(max(0, min(1, (db + 60) / 60)))

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.audioLevel = lvl
            if db < -40 {
                if self.silenceStart == nil { self.silenceStart = Date() }
            } else {
                self.silenceStart = nil
            }
        }
    }

    // MARK: - TTS

    private func speak(_ text: String, voice: String, toSpeaker: Bool) {
        guard !text.isEmpty else { return }
        let av = AVAudioSession.sharedInstance()
        if toSpeaker {
            try? av.overrideOutputAudioPort(.speaker)
            blockMic = true
        } else {
            try? av.overrideOutputAudioPort(.none)
            blockMic = false
        }
        let u   = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: voice)
        u.rate  = AVSpeechUtteranceDefaultSpeechRate
        isSpeaking = true
        synthesizer.speak(u)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension TranslatorEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish _: AVSpeechUtterance) {
        Task { @MainActor in
            guard !synthesizer.isSpeaking else { return }
            self.isSpeaking = false
            try? await Task.sleep(for: .milliseconds(250))
            self.blockMic = false
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel _: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false; self.blockMic = false }
    }
}
