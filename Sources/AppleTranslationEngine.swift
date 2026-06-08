import Foundation
import Translation
import Observation

/// Translation-only: Thai text → English via Apple Translation framework (iOS 18+).
/// ContentView must attach `.translationTask(appleEngine.translationConfig)`.
@Observable
@MainActor
final class AppleTranslationEngine {

    var translationConfig: TranslationSession.Configuration?

    private var sessionContinuation: CheckedContinuation<String, Error>?
    private var pendingText = ""

    // MARK: - Translate

    /// Called by TranslatorEngine after Qwen3 produces Thai text.
    func translate(_ thaiText: String) async throws -> String {
        // Cancel any in-flight request
        if let existing = sessionContinuation {
            existing.resume(throwing: CancellationError())
            sessionContinuation = nil
            translationConfig   = nil
        }
        pendingText = thaiText
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { [weak self] cont in
                guard let self else { cont.resume(throwing: CancellationError()); return }
                self.sessionContinuation = cont
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
    @MainActor
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
}
