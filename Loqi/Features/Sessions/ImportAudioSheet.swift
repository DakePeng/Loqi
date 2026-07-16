import SwiftUI

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// Configure an audio-file import (Voice Memos via the share sheet, or any
/// audio picked from Files). Import hands the work to the pipeline's job
/// center and dismisses immediately — progress lives under the session's
/// row in the Sessions list, not in this sheet.
struct ImportAudioSheet: View {
    let url: URL
    @Bindable var pipeline: CaptionPipeline
    @Environment(\.dismiss) private var dismiss

    @State private var sourceRaw: String
    /// Shared with the Record screen: empty = transcribe only (default).
    @AppStorage("captions.translation") private var translationRaw = ""
    // -1 = Auto (diarize). Default on so imports get speaker labels.
    // Recordings have no picker anymore — their post-process always runs
    // Auto when the model is downloaded — but imports keep this control
    // because a file's speaker count is often known up front. Per-import
    // @State, deliberately NOT remembered: an explicit count forces
    // EXACTLY that many clusters, so a stale "3 speakers" from last week's
    // meeting would split a solo lecture into three phantom speakers.
    // (The old "import.speakerCount" defaults key is intentionally unread.)
    @State private var speakerCount = -1
    @AppStorage("import.sensitivity") private var sensitivityRaw
        = MicSensitivity.balanced.rawValue
    /// Per-import engine choice. Defaults to the fast accurate option;
    /// Qwen3-ASR decodes near realtime, so it's an explicit pick per file,
    /// never an auto-upgrade (re-transcribe is the automatic Qwen3 pass).
    @State private var importEngine = SenseVoiceModelStore.isInstalled
        ? "sensevoice" : "apple"
    /// Shown when the user asks for speaker labels but the offline
    /// diarization model hasn't been downloaded yet — consent before a
    /// first-use network fetch.
    @State private var showSpeakerDownloadPrompt = false

    init(url: URL, pipeline: CaptionPipeline) {
        self.url = url
        self.pipeline = pipeline
        _sourceRaw = State(initialValue: Self.importLanguageRaw(
            UserDefaults.standard.string(forKey: "captions.source")))
    }

    static func importLanguageRaw(_ rawValue: String?) -> String {
        guard let rawValue, AppLanguage(rawValue: rawValue) != nil else {
            return AppLanguage.english.rawValue
        }
        return rawValue
    }

    static func importSensitivityRaw(_ rawValue: String?) -> String {
        guard let rawValue, MicSensitivity(rawValue: rawValue) != nil else {
            return MicSensitivity.balanced.rawValue
        }
        return rawValue
    }

    private var translationTarget: AppLanguage? { AppLanguage(rawValue: translationRaw) }
    private var source: AppLanguage { AppLanguage(rawValue: sourceRaw) ?? .english }
    private var sensitivity: MicSensitivity {
        MicSensitivity(rawValue: Self.importSensitivityRaw(sensitivityRaw)) ?? .balanced
    }

    /// Diarization is requested but the model isn't on disk yet.
    private var needsSpeakerModelConsent: Bool {
        VoiceprintService.separationEnabled(forPickerValue: speakerCount)
            && !VoiceprintService.isOfflineDiarizerDownloaded
    }

    private func startImport(speakerCount: Int) {
        // No sherpa runtime in the macOS target: diarizeFile throws
        // unsupportedPlatform there, so force separation off (the picker
        // is also hidden below).
        #if os(macOS)
        let speakerCount = 0
        #endif
        pipeline.jobs.startImport(
            url: url,
            direction: LanguagePair(
                source: source, target: translationTarget ?? source),
            speakerCount: speakerCount,
            engine: importEngine,
            sensitivity: sensitivity)
        dismiss()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("File", value: url.lastPathComponent)
                    Picker("Language", selection: $sourceRaw) {
                        ForEach(AppLanguage.allCases) {
                            Text($0.displayName).tag($0.rawValue)
                        }
                    }
                    .onChange(of: sourceRaw) {
                        UserDefaults.standard.set(sourceRaw, forKey: "captions.source")
                        if translationRaw == source.rawValue { translationRaw = "" }
                        // Dolphin has no English: switching the language
                        // hides its row, and a stale pick would silently
                        // fall through to Apple at import time.
                        if importEngine == "dolphin",
                           !OfflineTranscriber.dolphinSupports(source) {
                            importEngine = SenseVoiceModelStore.isInstalled
                                ? "sensevoice" : "apple"
                        }
                    }
                    Picker("Translation", selection: $translationRaw) {
                        Text("Off").tag("")
                        ForEach(AppLanguage.allCases.filter { $0 != source }) {
                            Text($0.displayName).tag($0.rawValue)
                        }
                    }
                    #if os(iOS)
                    Picker("Speakers", selection: $speakerCount) {
                        Text("One voice").tag(0)
                        Text("Auto").tag(-1)
                        ForEach(2...6, id: \.self) { Text("\($0) speakers").tag($0) }
                    }
                    #endif
                    if importEngine != "apple" {
                        Picker("Speech pickup", selection: $sensitivityRaw) {
                            ForEach(MicSensitivity.allCases) { preset in
                                Text(preset.displayName).tag(preset.rawValue)
                            }
                        }
                    }
                    Picker("Engine", selection: $importEngine) {
                        Text("Apple (instant)").tag("apple")
                        if SenseVoiceModelStore.isInstalled {
                            Text("SenseVoice (accurate)").tag("sensevoice")
                        }
                        if DolphinModelStore.isInstalled,
                           OfflineTranscriber.dolphinSupports(source) {
                            Text("Dolphin (fast, 中/日/한)").tag("dolphin")
                        }
                        if Qwen3ASRModelStore.isInstalled {
                            Text("Qwen3-ASR (highest accuracy)").tag("qwen3")
                        }
                    }
                } footer: {
                    if importEngine == "qwen3" {
                        Text("Highest accuracy — typically takes about as long as the recording itself. Everything runs on this iPhone.")
                    } else {
                        Text("Everything runs on this iPhone. Speaker separation downloads its model on first use.")
                    }
                }
            }
            .navigationTitle("Import Audio")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        if needsSpeakerModelConsent {
                            showSpeakerDownloadPrompt = true
                        } else {
                            startImport(speakerCount: speakerCount)
                        }
                    }
                    .disabled(pipeline.isRunning)
                }
            }
            .confirmationDialog(
                "Speaker labels need a one-time model download",
                isPresented: $showSpeakerDownloadPrompt,
                titleVisibility: .visible
            ) {
                Button("Download & Import") { startImport(speakerCount: speakerCount) }
                Button("Import Without Speakers") { startImport(speakerCount: 0) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The speaker-separation model downloads on first use, then runs entirely on this iPhone for this and future imports.")
            }
        }
    }
}
