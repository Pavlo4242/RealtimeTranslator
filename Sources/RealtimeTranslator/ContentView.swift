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
    // Explicitly hop to MainActor to handle the session
        Task { @MainActor in
            await engine.appleEngine.handleSession(session)
        }
    }
}
        .sheet(isPresented: $showHistory)  { HistoryView(store: engine.store) }
        .sheet(isPresented: $showSettings) {
            SettingsView(engine: engine, isPresented: $showSettings)
        }
        .overlay(alignment: .bottom) {
            if engine.showDebugLog { debugOverlay }
        }
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
                guard engine.messages.count > 0 else { return }
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
        switch qwenEngine.state {
        case .ready, .inferring:
            Label("Qwen3-ASR · ANE", systemImage: "brain.head.profile")
                .foregroundStyle(.cyan.opacity(0.6))
        case .loading:
            Label("Loading model…", systemImage: "arrow.down.circle")
                .foregroundStyle(.orange.opacity(0.6))
        case .failed:
            Label("Qwen3 unavailable", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red.opacity(0.7))
        default:
            EmptyView()
        }
    }
    .font(.caption2)
}

    // MARK: - Debug overlay

    private var debugOverlay: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(engine.debugLog) { entry in
                        Text(entry.text)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.green)
                            .id(entry.id)
                    }
                }
                .padding(6)
            }
            .frame(maxWidth: .infinity, maxHeight: 110)
            .background(Color.black.opacity(0.8))
            .onChange(of: engine.debugLog.count) {
                if let last = engine.debugLog.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
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
