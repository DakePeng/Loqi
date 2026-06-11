import SwiftUI

struct SettingsView: View {
    @Bindable var pipeline: CaptionPipeline

    @AppStorage("model.id") private var modelID: String = ModelCatalog.default.id
    @AppStorage("model.source") private var sourceRaw: String = ModelSource.huggingFace.rawValue
    @AppStorage("llm.enabled") private var llmEnabled = true
    @AppStorage("transcript.polish") private var transcriptPolish = true
    @AppStorage("diarizer.source") private var diarizerSourceRaw = DiarizerSource.huggingFace.rawValue
    @AppStorage("audio.saveRecordings") private var saveRecordings = true
    @AppStorage("asr.engine") private var asrEngine = "apple"
    @AppStorage("asr.source") private var asrSourceRaw = ASRModelSource.huggingFace.rawValue
    @State private var senseVoiceStore = SenseVoiceModelStore()
    @State private var senseVoiceInstalled = SenseVoiceModelStore.isInstalled
    @State private var diarizerState = "—"
    @State private var diarizerProgress: Double?
    @State private var diarizerError: String?
    @State private var tokensPerSecond: Double?
    @State private var llmState = "—"
    @State private var availableMemory = "—"
    @State private var downloadProgress: Double?
    @State private var downloadError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Engine", selection: $asrEngine) {
                        Text("Apple (instant)").tag("apple")
                        Text("SenseVoice (accurate)").tag("sensevoice")
                    }

                    if asrEngine == "sensevoice" {
                        LabeledContent(
                            "Recognition model",
                            value: senseVoiceInstalled
                                ? String(localized: "Downloaded")
                                : String(localized: "Not downloaded"))

                        if !senseVoiceInstalled {
                            Picker("Download from", selection: $asrSourceRaw) {
                                ForEach(ASRModelSource.allCases) { source in
                                    Text(source.displayName).tag(source.rawValue)
                                }
                            }
                            Button("Download SenseVoice model (~230 MB)") {
                                Task {
                                    let source = ASRModelSource(
                                        rawValue: asrSourceRaw) ?? .huggingFace
                                    await senseVoiceStore.download(from: source)
                                    senseVoiceInstalled = SenseVoiceModelStore.isInstalled
                                }
                            }
                            .disabled(senseVoiceStore.downloading)
                            if senseVoiceStore.downloading {
                                ProgressView(value: senseVoiceStore.progress)
                            }
                            if let error = senseVoiceStore.lastError {
                                Text(error)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                } header: {
                    Text("Speech recognition")
                } footer: {
                    Text("SenseVoice recognizes 中文, English, 日本語 and 한국어 with much higher accuracy — captions update in ~1-second pulses instead of word-by-word. Runs fully on this iPhone.")
                }

                Section("Enhanced translation model") {
                    Toggle("Enhanced translation (LLM)", isOn: $llmEnabled)
                        .onChange(of: llmEnabled) {
                            pipeline.setLLMEnabled(llmEnabled)
                        }

                    Toggle("Polish transcripts (LLM)", isOn: $transcriptPolish)
                        .disabled(!llmEnabled)

                    Group {
                        Picker("Model", selection: $modelID) {
                            ForEach(ModelCatalog.all) { option in
                                Text(option.displayName).tag(option.id)
                            }
                        }
                        .onChange(of: modelID) {
                            Task {
                                await pipeline.llm.setModel(ModelCatalog.option(for: modelID))
                                await refreshStats()
                            }
                        }

                        Picker("Download from", selection: $sourceRaw) {
                            ForEach(ModelSource.allCases) { source in
                                Text(source.displayName).tag(source.rawValue)
                            }
                        }
                        .onChange(of: sourceRaw) {
                            Task {
                                let source = ModelSource(rawValue: sourceRaw) ?? .huggingFace
                                await pipeline.llm.setSource(source)
                            }
                        }

                        Button("Download model now") {
                            Task {
                                downloadError = nil
                                downloadProgress = 0
                                do {
                                    try await pipeline.llm.load { progress in
                                        Task { @MainActor in downloadProgress = progress }
                                    }
                                } catch {
                                    downloadError = error.localizedDescription
                                }
                                downloadProgress = nil
                                await refreshStats()
                            }
                        }
                        if let downloadProgress {
                            ProgressView(value: downloadProgress)
                        }
                        if let downloadError {
                            Text(downloadError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    .disabled(!llmEnabled)
                }

                Section {
                    Picker("Download from", selection: $diarizerSourceRaw) {
                        ForEach(DiarizerSource.allCases) { source in
                            Text(source.displayName).tag(source.rawValue)
                        }
                    }

                    Button("Download speaker model") {
                        downloadSpeakerModel()
                    }
                    .disabled(diarizerProgress != nil)
                    if let diarizerProgress {
                        ProgressView(value: diarizerProgress)
                    }
                    if let diarizerError {
                        Text(diarizerError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    LabeledContent("Speaker model", value: diarizerState)

                } header: {
                    Text("Speaker recognition")
                } footer: {
                    Text("Powers speaker separation for recordings and imported audio. Voice data never leaves this iPhone. Use HF-Mirror if Hugging Face is unreachable — this model is not available on ModelScope.")
                }

                Section {
                    Toggle("Save audio recordings", isOn: $saveRecordings)
                } header: {
                    Text("Recording")
                } footer: {
                    Text("Keep each session's audio alongside its transcript. Recordings are stored only on this iPhone and are deleted with their session.")
                }

                Section("Vocabulary") {
                    NavigationLink {
                        HotwordsView(store: pipeline.hotwords)
                    } label: {
                        LabeledContent(
                            "Hotwords",
                            value: pipeline.hotwords.hotwords.isEmpty
                                ? "" : "\(pipeline.hotwords.hotwords.count)")
                    }
                }

                Section("Diagnostics") {
                    LabeledContent("Model state", value: llmState)
                    LabeledContent("Available memory", value: availableMemory)
                    LabeledContent("Thermal state", value: thermalLabel)
                    if let tokensPerSecond {
                        LabeledContent(
                            "Last generation",
                            value: String(format: "%.1f tok/s", tokensPerSecond))
                    }
                }

                Section {
                    Text("All transcription and translation run on this iPhone. The network is used only to download models.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .task {
                // Sync persisted choices into the service on first appearance.
                await pipeline.llm.setModel(ModelCatalog.option(for: modelID))
                await pipeline.llm.setSource(ModelSource(rawValue: sourceRaw) ?? .huggingFace)
                await refreshStats()
            }
            .refreshable { await refreshStats() }
        }
    }

    private var thermalLabel: String {
        switch pipeline.thermal.thermalState {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious — refinement paused"
        case .critical: "Critical — LLM off"
        @unknown default: "Unknown"
        }
    }

    private func downloadSpeakerModel() {
        Task {
            diarizerError = nil
            diarizerProgress = 0
            let source = DiarizerSource(rawValue: diarizerSourceRaw) ?? .huggingFace
            do {
                try await pipeline.voiceprint.loadIfNeeded(source: source) { progress in
                    Task { @MainActor in diarizerProgress = progress }
                }
            } catch {
                diarizerError = error.localizedDescription
            }
            diarizerProgress = nil
            await refreshStats()
        }
    }

    private func refreshStats() async {
        switch await pipeline.llm.loadState {
        case .unloaded: llmState = "Not loaded"
        case .downloading(let p): llmState = "Downloading \(Int(p * 100))%"
        case .loading: llmState = "Loading"
        case .ready: llmState = "Ready"
        case .failed(let reason): llmState = "Failed: \(reason)"
        }
        let bytes = await pipeline.llm.available()
        availableMemory = ByteCountFormatter.string(
            fromByteCount: Int64(bytes), countStyle: .memory)
        let speed = await pipeline.llm.lastTokensPerSecond
        tokensPerSecond = speed > 0 ? speed : nil

        switch await pipeline.voiceprint.state {
        case .unloaded:
            diarizerState = VoiceprintService.isModelCached
                ? "Downloaded (not loaded)" : "Not downloaded"
        case .downloading(let p): diarizerState = "Downloading \(Int(p * 100))%"
        case .loading: diarizerState = "Loading"
        case .ready: diarizerState = "Ready"
        case .failed(let reason): diarizerState = "Failed: \(reason)"
        }
    }
}
