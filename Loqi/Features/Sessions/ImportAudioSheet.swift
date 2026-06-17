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

    @AppStorage("captions.source") private var sourceRaw = AppLanguage.english.rawValue
    /// Shared with the Record screen: empty = transcribe only (default).
    @AppStorage("captions.translation") private var translationRaw = ""
    @AppStorage("captions.speakerCount") private var speakerCount = 0
    /// Per-import engine choice. Defaults to the fast accurate option;
    /// Qwen3-ASR decodes near realtime, so it's an explicit pick per file,
    /// never an auto-upgrade (re-transcribe is the automatic Qwen3 pass).
    @State private var importEngine = SenseVoiceModelStore.isInstalled
        ? "sensevoice" : "apple"
    /// Shown when the user asks for speaker labels but the offline
    /// diarization model hasn't been downloaded yet — consent before a
    /// first-use network fetch.
    @State private var showSpeakerDownloadPrompt = false

    private var translationTarget: AppLanguage? { AppLanguage(rawValue: translationRaw) }
    private var source: AppLanguage { AppLanguage(rawValue: sourceRaw) ?? .english }

    /// Diarization is requested but the model isn't on disk yet.
    private var needsSpeakerModelConsent: Bool {
        VoiceprintService.clusterCap(forPickerValue: speakerCount) != nil
            && !VoiceprintService.isOfflineDiarizerDownloaded
    }

    private func startImport(speakerCount: Int) {
        pipeline.jobs.startImport(
            url: url,
            direction: LanguagePair(
                source: source, target: translationTarget ?? source),
            speakerCount: speakerCount,
            engine: importEngine)
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
                        if translationRaw == source.rawValue { translationRaw = "" }
                    }
                    Picker("Translation", selection: $translationRaw) {
                        Text("Off").tag("")
                        ForEach(AppLanguage.allCases.filter { $0 != source }) {
                            Text($0.displayName).tag($0.rawValue)
                        }
                    }
                    Picker("Speakers", selection: $speakerCount) {
                        Text("One voice").tag(0)
                        Text("Auto").tag(-1)
                        ForEach(2...6, id: \.self) { Text("\($0) speakers").tag($0) }
                    }
                    Picker("Engine", selection: $importEngine) {
                        Text("Apple (instant)").tag("apple")
                        if SenseVoiceModelStore.isInstalled {
                            Text("SenseVoice (accurate)").tag("sensevoice")
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
