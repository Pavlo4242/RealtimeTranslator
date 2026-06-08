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
@MainActor
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