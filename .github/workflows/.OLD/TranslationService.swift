Yes — adding Apple's Foundation Models as a fallback or user-configurable toggle is straightforward and highly recommended for your Thai → English realtime translator.
This fits perfectly into the refactor plan you provided (whisper.cpp + CoreML for ASR).
Why This Is a Great Addition

Primary path: Whisper.cpp (Typhoon Isan model via CoreML) → typhoon-translate1.5-4b (or similar) for high-quality, controllable Thai-specific translation.
Fallback / Toggle: Use Foundation Models (FoundationModels framework) when the dedicated translation model fails to load, for battery/thermal reasons, or when the user prefers the built-in Apple model.
Benefits: Reduces memory pressure, leverages Apple’s optimized on-device LLM (~3B params), excellent instruction-following for translation + code-switching cleanup, and simplifies the app for users on supported devices.

Requirements:

Deployment target remains iOS 26.0 (already in the plan).
Device must support Apple Intelligence (iPhone 15 Pro / 16 / 17 series and newer, with the feature enabled).

Implementation Outline (on top of the Refactor Plan)
1. New File: TranslationService.swift (or extend TranslatorEngine.swift)
Create a protocol + implementations for clean toggling.
Swiftimport Foundation
import FoundationModels  // iOS 26+

protocol TranslationService {
    func translate(thaiText: String) async throws -> String
    var isAvailable: Bool { get }
}

@MainActor
class TranslationManager: ObservableObject {
    enum Mode: String, CaseIterable {
        case typhoon = "Typhoon Translate 1.5 (4B)"
        case appleFoundation = "Apple Foundation Model (Fallback)"
    }
    
    @Published var selectedMode: Mode = .typhoon
    private var typhoonService: TyphoonTranslationService?  // your MLX / llama.cpp wrapper
    private let foundationService = FoundationTranslationService()
    
    func translate(_ text: String) async throws -> String {
        switch selectedMode {
        case .typhoon:
            if let typhoon = typhoonService, typhoon.isAvailable {
                return try await typhoon.translate(thaiText: text)
            } else {
                return try await foundationService.translate(thaiText: text)  // auto fallback
            }
        case .appleFoundation:
            return try await foundationService.translate(thaiText: text)
        }
    }
}

// MARK: - Apple Foundation Models Implementation
class FoundationTranslationService: TranslationService {
    private let model = SystemLanguageModel.default  // or .general use case
    
    var isAvailable: Bool {
        switch model.availability {
        case .available: return true
        default: return false
        }
    }
    
    func translate(thaiText: String) async throws -> String {
        guard isAvailable else {
            throw TranslationError.modelUnavailable
        }
        
        let session = LanguageModelSession(instructions: """
            You are an expert Thai-to-English translator.
            - Translate naturally and conversationally.
            - Preserve English loanwords (meeting, app, WiFi, etc.).
            - Handle code-switching smoothly.
            - Return ONLY the English translation, no explanations.
            """)
        
        let response = try await session.respond(to: "Translate this Thai text to English:\n\(thaiText)")
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}