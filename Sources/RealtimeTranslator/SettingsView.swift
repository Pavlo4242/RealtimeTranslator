import SwiftUI

struct SettingsView: View {
    @Bindable var engine: TranslatorEngine
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.07).ignoresSafeArea()
                Form {
                    // ── Qwen3-ASR status ──────────────────────────────────
                    Section("Qwen3-ASR (Thai → Thai text)") {
                        qwenStatusRow
                        if case .failed = engine.qwenEngine.state {
                            Button("Retry download") {
                                Task { await engine.qwenEngine.setup() }
                            }
                            .foregroundStyle(.cyan)
                        }
                    }
                    .listRowBackground(Color(white: 0.14))

                    // ── Apple Translation status ──────────────────────────
                    Section("Apple Translation (Thai text → English)") {
                        HStack {
                            Text("System framework")
                            Spacer()
                            Text("✓ Always available")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    .listRowBackground(Color(white: 0.14))

                    // ── Developer ─────────────────────────────────────────
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
    private var qwenStatusRow: some View {
        HStack {
            Text("qwen3-asr-0.6b · INT8 (~0.6 GB)")
            Spacer()
            switch engine.qwenEngine.state {
            case .idle:
                Text("Not started").font(.caption).foregroundStyle(.white.opacity(0.35))
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
                Text("✗ \(e.prefix(30))").font(.caption).foregroundStyle(.red)
            }
        }
    }
}
