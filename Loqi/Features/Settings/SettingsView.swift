import SwiftUI

struct SettingsView: View {
    @Bindable var pipeline: CaptionPipeline

    @AppStorage(AppUILanguage.defaultsKey) private var appLanguageRaw = AppUILanguage.system.rawValue
    @AppStorage("model.id") private var modelID: String = ModelCatalog.default.id
    @AppStorage("model.source") private var sourceRaw: String = ModelSource.huggingFace.rawValue
    @AppStorage("llm.enabled") private var llmEnabled = true
    @AppStorage(DiarizerModelStore.sourceDefaultsKey) private var diarizerSourceRaw = ASRModelSource.huggingFace.rawValue
    @AppStorage("audio.saveRecordings") private var saveRecordings = true
    @AppStorage("display.keepScreenOn") private var keepScreenOn = true
    @AppStorage("perf.reduceHeat") private var reduceHeat = false
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
    @State private var diarizerInstalled = VoiceprintService.isOfflineDiarizerDownloaded
    @State private var diarizerDownloading = false
    @State private var diarizerError: String?
    @State private var diarizerSpeedometer = DownloadSpeedometer()
    @State private var senseVoiceSpeedometer = DownloadSpeedometer()
    @State private var tokensPerSecond: Double?
    @State private var llmActiveSeconds: Double = 0
    @State private var asrActiveSeconds: Double = 0
    @State private var thermalTransitions = 0
    @State private var llmState = "—"
    @State private var liveDownloaded = false
    @State private var summaryDownloaded = false
    @State private var availableMemory = "—"
    // ponytail: one in-flight download (the LLM actor serializes loads); the
    // id picks which row renders the progress bar. Per-row flags would buy
    // nothing the actor doesn't already enforce.
    @State private var downloadingModelID: String?
    @State private var llmSpeedometer = DownloadSpeedometer()
    @State private var downloadError: String?


    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("App language", selection: $appLanguageRaw) {
                        Text("Follow iPhone").tag(AppUILanguage.system.rawValue)
                        Text("English").tag(AppUILanguage.english.rawValue)
                        Text("Simplified Chinese").tag(AppUILanguage.chinese.rawValue)
                    }
                } header: {
                    Text("Language")
                }

                Section {
                    Picker("Engine", selection: $asrEngine) {
                        Text("Apple (instant)").tag("apple")
                        Text("SenseVoice (accurate)").tag("sensevoice")
                    }

                    if asrEngine == "sensevoice" {
                        LabeledContent(
                            "Recognition model",
                            value: senseVoiceInstalled
                                ? localized("Downloaded")
                                : localized("Not downloaded"))

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
                            ? localized("Downloaded")
                            : localized("Not downloaded"))

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
                        // Live tier — runs during recording, locked to the
                        // 230M transcript-cleanup model (no vision tower:
                        // photos attached live keep OCR text and live notes
                        // wait for post-session mapping).
                        LabeledContent("Live model", value: "Liquid LFM2.5 230M")
                        LabeledContent(
                            "Live model files",
                            value: liveDownloaded
                                ? localized("Downloaded")
                                : localized("Not downloaded"))
                        if !liveDownloaded {
                            if downloadingModelID == ModelCatalog.liveRefineModel.id {
                                DownloadProgressRow(
                                    speedometer: llmSpeedometer, onStop: stopDownload)
                            } else {
                                Button("Download live model") {
                                    startDownload(ModelCatalog.liveRefineModel)
                                }
                                .disabled(downloadingModelID != nil)
                            }
                        }

                        // Summary tier — user's pick, runs after recording.
                        Picker("Summary model", selection: $modelID) {
                            ForEach(ModelCatalog.all) { option in
                                Text(modelDisplayName(option)).tag(option.id)
                            }
                        }
                        .onChange(of: modelID) {
                            Task {
                                await pipeline.llm.setModel(ModelCatalog.option(for: modelID))
                                await refreshStats()
                            }
                        }
                        LabeledContent(
                            "Summary model files",
                            value: summaryDownloaded
                                ? localized("Downloaded")
                                : localized("Not downloaded"))
                        if !summaryDownloaded {
                            let summary = ModelCatalog.option(for: modelID)
                            if downloadingModelID == summary.id {
                                DownloadProgressRow(
                                    speedometer: llmSpeedometer, onStop: stopDownload)
                            } else {
                                Button("Download summary model") {
                                    startDownload(summary)
                                }
                                .disabled(downloadingModelID != nil)
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

                        if let downloadError {
                            Text(downloadError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    .disabled(!llmEnabled)
                } header: {
                    Text("On-device AI")
                } footer: {
                    Text("During a recording, the tiny on-device Liquid LFM2.5 model cleans up the live transcript — fixing misheard words, names, and punctuation — while Apple's system translation produces the translation itself. Live notes and photo descriptions are generated after the recording ends. After a recording, summaries, titles, vocabulary and chat use the summary model you pick above.")
                }

                Section {
                    if !diarizerInstalled {
                        Picker("Download from", selection: $diarizerSourceRaw) {
                            ForEach(ASRModelSource.allCases) { source in
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
                    Text("Powers speaker separation for recordings and imported audio. Voice data never leaves this iPhone. Use ModelScope if Hugging Face is unreachable.")
                }

                Section {
                    Toggle("Save audio recordings", isOn: $saveRecordings)
                    Toggle("Keep screen on while recording", isOn: $keepScreenOn)
                } header: {
                    Text("Recording")
                } footer: {
                    Text("Keep each session's audio alongside its transcript. Recordings are stored only on this iPhone and are deleted with their session. Turning off “Keep screen on” lets the display sleep during long recordings — captions keep running and it runs noticeably cooler.")
                }

                Section {
                    Toggle("Reduce heat", isOn: $reduceHeat)
                } header: {
                    Text("Performance")
                } footer: {
                    Text("Lowers sustained heat during long recordings: slower live-caption updates, fewer speech recognition threads, and refinement only on longer sentences. Takes effect on the next recording.")
                }

                Section("Diagnostics") {
                    LabeledContent("Model state", value: llmState)
                    LabeledContent("Available memory", value: availableMemory)
                    LabeledContent("Thermal state", value: thermalLabel)
                    LabeledContent("Thermal changes", value: "\(thermalTransitions)")
                    if let tokensPerSecond {
                        LabeledContent(
                            "Last generation",
                            value: String(
                                format: localized("%.1f tok/s"),
                                locale: appUILanguage.locale,
                                tokensPerSecond))
                    }
                    LabeledContent(
                        "LLM active",
                        value: String(
                            format: localized("%.1f s"),
                            locale: appUILanguage.locale,
                            llmActiveSeconds))
                    LabeledContent(
                        "ASR active",
                        value: String(
                            format: localized("%.1f s"),
                            locale: appUILanguage.locale,
                            asrActiveSeconds))
                    LabeledContent(
                        "Heat driver",
                        value: SessionHeatStats.dominant(
                            llmSeconds: llmActiveSeconds, asrSeconds: asrActiveSeconds))
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
            .onChange(of: appLanguageRaw) {
                Task { await refreshStats() }
            }
        }
    }

    private var thermalLabel: String {
        switch pipeline.thermal.thermalState {
        case .nominal: localized("Nominal")
        case .fair: localized("Fair")
        case .serious: localized("Serious — AI work paused")
        case .critical: localized("Critical — AI model off")
        @unknown default: localized("Unknown")
        }
    }

    private var appUILanguage: AppUILanguage {
        AppUILanguage(rawValue: appLanguageRaw) ?? .system
    }

    private func localized(_ value: String.LocalizationValue) -> String {
        String(localized: value, locale: appUILanguage.locale)
    }

    private func modelDisplayName(_ option: ModelOption) -> String {
        switch option.id {
        case ModelCatalog.qwen35_2b.id:
            localized("Qwen3.5 2B — recommended")
        case ModelCatalog.bonsai8b.id:
            localized("Bonsai 8B (ternary 2-bit)")
        default:
            option.displayName
        }
    }

    private func downloadSpeakerModel() {
        diarizerError = nil
        diarizerDownloading = true
        diarizerSpeedometer.start(totalBytes: VoiceprintService.approximateDownloadBytes)
        Task {
            let source = ASRModelSource(rawValue: diarizerSourceRaw) ?? .huggingFace
            do {
                try await VoiceprintService.downloadModels(source: source) { progress in
                    Task { @MainActor in diarizerSpeedometer.update(progress) }
                }
            } catch {
                diarizerError = error.localizedDescription
            }
            diarizerDownloading = false
            await refreshStats()
        }
    }

    private func startDownload(_ model: ModelOption) {
        downloadError = nil
        downloadingModelID = model.id
        llmSpeedometer.start(totalBytes: model.downloadBytes)
        Task {
            await pipeline.llm.setModel(model)
            do {
                try await pipeline.llm.load { progress in
                    Task { @MainActor in llmSpeedometer.update(progress) }
                }
            } catch is CancellationError {
                // Stopped by the user — not an error.
            } catch {
                downloadError = error.localizedDescription
            }
            // Restore the user's summary pick as the resident model.
            await pipeline.llm.setModel(ModelCatalog.option(for: modelID))
            downloadingModelID = nil
            await refreshStats()
        }
    }

    private func stopDownload() {
        Task { await pipeline.llm.cancelLoad() }
    }

    private func refreshStats() async {
        switch await pipeline.llm.loadState {
        case .unloaded: llmState = localized("Not loaded")
        case .downloading(let p): llmState = localized("Downloading \(Int(p * 100))%")
        case .loading: llmState = localized("Loading")
        case .ready: llmState = localized("Ready")
        case .failed(let reason): llmState = localized("Failed: \(reason)")
        }
        liveDownloaded = LLMService.isDownloaded(model: ModelCatalog.liveRefineModel)
        summaryDownloaded = LLMService.isDownloaded(
            model: ModelCatalog.option(for: modelID))
        let bytes = await pipeline.llm.available()
        availableMemory = ByteCountFormatter.string(
            fromByteCount: Int64(bytes), countStyle: .memory)
        let speed = await pipeline.llm.lastTokensPerSecond
        tokensPerSecond = speed > 0 ? speed : nil
        llmActiveSeconds = await pipeline.llm.generateActiveSeconds
        asrActiveSeconds = await pipeline.activeSenseVoiceDecodeSeconds()
        thermalTransitions = pipeline.thermal.transitions.count
        senseVoiceInstalled = SenseVoiceModelStore.isInstalled
        qwen3Installed = Qwen3ASRModelStore.isInstalled

        diarizerInstalled = VoiceprintService.isOfflineDiarizerDownloaded
        // Stateless offline pipeline: downloaded or not is the whole story
        // (each post-process/import run loads and releases its own manager).
        diarizerState = diarizerInstalled
            ? localized("Downloaded")
            : localized("Not downloaded")
    }
}
