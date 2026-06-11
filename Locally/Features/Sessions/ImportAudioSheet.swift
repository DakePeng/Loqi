import SwiftUI

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// Configure and run an audio-file import (Voice Memos via the share sheet,
/// or any audio picked from Files).
struct ImportAudioSheet: View {
    let url: URL
    @Bindable var pipeline: CaptionPipeline
    @Environment(\.dismiss) private var dismiss

    @AppStorage("captions.source") private var source: AppLanguage = .english
    @AppStorage("captions.target") private var target: AppLanguage = .chinese
    @AppStorage("captions.speakerCount") private var speakerCount = 0
    @State private var phase: FileImportEngine.Phase?
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("File", value: url.lastPathComponent)
                    Picker("Source language", selection: $source) {
                        ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Target language", selection: $target) {
                        ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Speakers", selection: $speakerCount) {
                        Text("One voice").tag(0)
                        ForEach(2...6, id: \.self) { Text("\($0) speakers").tag($0) }
                    }
                } footer: {
                    if source == target {
                        Text("Same language selected: the recording will be transcribed without translation.")
                    } else {
                        Text("Transcription and translation run fully on-device. Speaker separation requires the speaker model (Settings).")
                    }
                }

                if let phase {
                    Section {
                        switch phase {
                        case .transcribing(let fraction):
                            ProgressView(value: fraction) { Text("Transcribing…") }
                        case .identifyingSpeakers(let fraction):
                            ProgressView(value: fraction) { Text("Identifying speakers…") }
                        case .translating(let fraction):
                            ProgressView(value: fraction) { Text("Translating…") }
                        }
                    }
                }

                if let importError {
                    Section {
                        Text(importError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Import Audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(phase != nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { runImport() }
                        .disabled(phase != nil || pipeline.isRunning)
                }
            }
            .interactiveDismissDisabled(phase != nil)
        }
    }

    private func runImport() {
        importError = nil
        phase = .transcribing(0)
        Task {
            defer { phase = nil }
            do {
                let engine = FileImportEngine(
                    translator: pipeline.translator,
                    voiceprint: pipeline.voiceprint)
                let record = try await engine.importAudio(
                    url: url,
                    direction: LanguagePair(source: source, target: target),
                    speakerCount: speakerCount
                ) { phase in
                    self.phase = phase
                }
                pipeline.archive.add(record)
                dismiss()
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}
