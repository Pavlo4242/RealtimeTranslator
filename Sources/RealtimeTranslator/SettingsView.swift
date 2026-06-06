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
                        Picker("Model Size", selection: $engine.whisperEngine.modelPreference) {
                            ForEach(WhisperModel.allCases) { m in
                                Text(m.displayName).tag(m)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: engine.whisperEngine.modelPreference) { _, newValue in
                            Task { await engine.whisperEngine.changeModel(to: newValue) }
                        }
                        
                        whisperStatusRow
                        if case .failed = engine.whisperEngine.state {
                            Button("Retry download") {
                                Task { await engine.whisperEngine.setup() }
                            }
                            .foregroundStyle(.cyan)
                            .disabled(engine.whisperEngine.state == .inferring)
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

                    // ── Developer ────────────────────────────────────────
                    Section("Developer") {
                        Toggle("Show debug log", isOn: $engine.showDebugLog)
                        ShareLink(item: engine.exportableLog) {
                            Label("Export Debug Log", systemImage: "square.and.arrow.up")
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
            Text(engine.whisperEngine.modelPreference.rawValue)
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