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