import SwiftUI

struct SettingsView: View {
    @Bindable var pipeline: CaptionPipeline

    @AppStorage("model.id") private var modelID: String = ModelCatalog.default.id
    @AppStorage("model.source") private var sourceRaw: String = ModelSource.huggingFace.rawValue
    @AppStorage("llm.enabled") private var llmEnabled = true
    @AppStorage(DiarizerSource.defaultsKey) private var diarizerSourceRaw = DiarizerSource.huggingFace.rawValue
    @AppStorage("audio.saveRecordings") private var saveRecordings = true
    @AppStorage("asr.engine") private var asrEngine = "apple"
    @AppStorage("asr.source") private var asrSourceRaw = ASRModelSource.modelScope.rawValue
    @AppStorage("summary.autoPostProcessNewRecordings")
    private var autoPostProcessNewRecordings = false
    @State private var senseVoiceStore = SenseVoiceModelStore()
    @State private var senseVoiceInstalled = SenseVoiceModelStore.isInstalled
    @State private var qwen3Store = Qwen3ASRModelStore()
    @State private var qwen3Installed = Qwen3ASRModelStore.isInstalled
    @State private var qwen3Speedometer = DownloadSpeedometer()
    @State private var diarizerState = "—"
    @State private var diarizerInstalled = StreamingDiarizer.isModelCached
    @State private var diarizerDownloading = false
    @State private var diarizerError: String?
    @State private var diarizerSpeedometer = DownloadSpeedometer()
    @State private var senseVoiceSpeedometer = DownloadSpeedometer()
    @State private var tokensPerSecond: Double?
    @State private var llmState = "—"
    @State private var llmDownloaded = false
    @State private var availableMemory = "—"
    @State private var llmDownloading = false
    @State private var llmSpeedometer = DownloadSpeedometer()
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
                            if senseVoiceStore.downloading {
                                DownloadProgressRow(
                                    speedometer: senseVoiceSpeedometer,
                                    onStop: { senseVoiceStore.cancelDownload() })
                            } else {
                                Button("Download SenseVoice model (~230 MB)") {
                                    senseVoiceSpeedometer.start(
                                        totalBytes: SenseVoiceModelStore.totalExpectedBytes)
                                    Task {
                                        let source = ASRModelSource(
                                            rawValue: asrSourceRaw) ?? .modelScope
                                        await senseVoiceStore.download(from: source)
                                        senseVoiceInstalled = SenseVoiceModelStore.isInstalled
                                    }
                                }
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

                Section {
                    Toggle(
                        "Auto post-process new recordings",
                        isOn: $autoPostProcessNewRecordings)

                    LabeledContent(
                        "Qwen3-ASR model",
                        value: qwen3Installed
                            ? String(localized: "Downloaded")
                            : String(localized: "Not downloaded"))

                    if !qwen3Installed {
                        Picker("Download from", selection: $asrSourceRaw) {
                            ForEach(ASRModelSource.allCases) { source in
                                Text(source.displayName).tag(source.rawValue)
                            }
                        }
                        if qwen3Store.downloading {
                            DownloadProgressRow(
                                speedometer: qwen3Speedometer,
                                onStop: { qwen3Store.cancelDownload() })
                        } else {
                            Button("Download Qwen3-ASR model (~990 MB)") {
                                qwen3Speedometer.start(
                                    totalBytes: Qwen3ASRModelStore.totalExpectedBytes)
                                Task {
                                    let source = ASRModelSource(
                                        rawValue: asrSourceRaw) ?? .modelScope
                                    await qwen3Store.download(from: source)
                                    qwen3Installed = Qwen3ASRModelStore.isInstalled
                                }
                            }
                        }
                        if let error = qwen3Store.lastError {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("High-accuracy re-transcription")
                } footer: {
                    Text("Once downloaded, Re-transcribe & summarize uses Qwen3-ASR automatically, and imports can select it. Auto post-process re-transcribes and identifies speakers before the first summary for new recordings, using downloaded models only. Live captions stay on the fast engines.")
                }

                Section {
                    Toggle("AI features", isOn: $llmEnabled)
                        .onChange(of: llmEnabled) {
                            pipeline.setLLMEnabled(llmEnabled)
                        }

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

                        LabeledContent(
                            "Model files",
                            value: llmDownloaded
                                ? String(localized: "Downloaded")
                                : String(localized: "Not downloaded"))

                        if !llmDownloaded {
                            if llmDownloading {
                                DownloadProgressRow(
                                    speedometer: llmSpeedometer,
                                    onStop: stopDownload)
                            } else {
                                Button("Download model now") { startDownload() }
                            }
                            if let downloadError {
                                Text(downloadError)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    .disabled(!llmEnabled)
                } header: {
                    Text("On-device AI")
                } footer: {
                    Text("One local model powers better translations, summaries, titles, chat and vocabulary suggestions. Turning AI features off disables all of them. The model downloads only when you ask — here, or when a feature offers it.")
                }

                Section {
                    if !diarizerInstalled {
                        Picker("Download from", selection: $diarizerSourceRaw) {
                            ForEach(DiarizerSource.allCases) { source in
                                Text(source.displayName).tag(source.rawValue)
                            }
                        }

                        if diarizerDownloading {
                            DownloadProgressRow(speedometer: diarizerSpeedometer)
                        } else {
                            Button("Download speaker model") {
                                downloadSpeakerModel()
                            }
                        }
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
                    Text("All transcription, translation and summaries run on this iPhone. The network is used only for model downloads you start.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .tabHeaderTitle("Settings")
            .task {
                // Sync persisted choices into the service, then keep the
                // diagnostics live while the screen is visible — downloads
                // started elsewhere (a consent prompt, the pipeline's warm
                // load) must show here without pull-to-refresh.
                await pipeline.llm.setModel(ModelCatalog.option(for: modelID))
                await pipeline.llm.setSource(ModelSource(rawValue: sourceRaw) ?? .huggingFace)
                while !Task.isCancelled {
                    await refreshStats()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            .refreshable { await refreshStats() }
            .onChange(of: senseVoiceStore.progress) { _, p in
                senseVoiceSpeedometer.update(p)
            }
            .onChange(of: qwen3Store.progress) { _, p in
                qwen3Speedometer.update(p)
            }
        }
    }

    private var thermalLabel: String {
        switch pipeline.thermal.thermalState {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious — AI work paused"
        case .critical: "Critical — AI model off"
        @unknown default: "Unknown"
        }
    }

    private func downloadSpeakerModel() {
        diarizerError = nil
        diarizerDownloading = true
        diarizerSpeedometer.start(totalBytes: StreamingDiarizer.approximateDownloadBytes)
        Task {
            let source = DiarizerSource(rawValue: diarizerSourceRaw) ?? .huggingFace
            do {
                try await pipeline.streamingDiarizer.loadIfNeeded(source: source) { progress in
                    Task { @MainActor in diarizerSpeedometer.update(progress) }
                }
            } catch {
                diarizerError = error.localizedDescription
            }
            diarizerDownloading = false
            await refreshStats()
        }
    }

    private func startDownload() {
        downloadError = nil
        llmDownloading = true
        llmSpeedometer.start(totalBytes: ModelCatalog.option(for: modelID).downloadBytes)
        Task {
            do {
                try await pipeline.llm.load { progress in
                    Task { @MainActor in llmSpeedometer.update(progress) }
                }
            } catch is CancellationError {
                // Stopped by the user — not an error.
            } catch {
                downloadError = error.localizedDescription
            }
            llmDownloading = false
            await refreshStats()
        }
    }

    private func stopDownload() {
        Task { await pipeline.llm.cancelLoad() }
    }

    private func refreshStats() async {
        switch await pipeline.llm.loadState {
        case .unloaded: llmState = String(localized: "Not loaded")
        case .downloading(let p): llmState = String(localized: "Downloading \(Int(p * 100))%")
        case .loading: llmState = String(localized: "Loading")
        case .ready: llmState = String(localized: "Ready")
        case .failed(let reason): llmState = String(localized: "Failed: \(reason)")
        }
        llmDownloaded = LLMService.isDownloaded(model: ModelCatalog.option(for: modelID))
        let bytes = await pipeline.llm.available()
        availableMemory = ByteCountFormatter.string(
            fromByteCount: Int64(bytes), countStyle: .memory)
        let speed = await pipeline.llm.lastTokensPerSecond
        tokensPerSecond = speed > 0 ? speed : nil
        senseVoiceInstalled = SenseVoiceModelStore.isInstalled
        qwen3Installed = Qwen3ASRModelStore.isInstalled

        diarizerInstalled = StreamingDiarizer.isModelCached
        switch await pipeline.streamingDiarizer.state {
        case .unloaded:
            diarizerState = diarizerInstalled
                ? String(localized: "Downloaded (not loaded)")
                : String(localized: "Not downloaded")
        case .downloading(let p): diarizerState = String(localized: "Downloading \(Int(p * 100))%")
        case .loading: diarizerState = String(localized: "Loading")
        case .ready: diarizerState = String(localized: "Ready")
        case .failed(let reason): diarizerState = String(localized: "Failed: \(reason)")
        }
    }
}
