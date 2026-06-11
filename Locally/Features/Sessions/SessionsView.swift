import SwiftUI

/// Saved sessions: list, transcript detail, on-device summary, Markdown
/// export, speaker renaming, and hotword suggestions.
struct SessionsView: View {
    @Bindable var pipeline: CaptionPipeline
    @State private var pickingFile = false
    @State private var importURL: URL?

    var body: some View {
        NavigationStack {
            List {
                ForEach(pipeline.archive.sessions) { session in
                    NavigationLink {
                        SessionDetailView(pipeline: pipeline, sessionID: session.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.title)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Image(systemName: session.mode == .captions
                                    ? "captions.bubble" : "bubble.left.and.bubble.right")
                                Text(session.startedAt, style: .date)
                                Text(session.startedAt, style: .time)
                                Text("· \(session.entries.count)")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { pipeline.archive.delete(at: $0) }
            }
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Import audio", systemImage: "square.and.arrow.down") {
                        pickingFile = true
                    }
                    .disabled(pipeline.isRunning)
                }
            }
            .fileImporter(
                isPresented: $pickingFile,
                allowedContentTypes: [.audio]
            ) { result in
                if case .success(let url) = result {
                    importURL = url
                }
            }
            .sheet(item: $importURL) { url in
                ImportAudioSheet(url: url, pipeline: pipeline)
            }
            .overlay {
                if pipeline.archive.sessions.isEmpty {
                    ContentUnavailableView(
                        "No sessions yet",
                        systemImage: "clock",
                        description: Text("Finished sessions are saved here automatically."))
                }
            }
        }
    }
}

private struct SessionDetailView: View {
    @Bindable var pipeline: CaptionPipeline
    let sessionID: UUID

    @State private var summarizing = false
    @State private var summarizeProgress: (done: Int, total: Int)?
    @State private var suggesting = false
    @State private var suggestions: [(term: String, note: String)] = []
    @State private var actionError: String?
    @State private var renamingSlot: Int?
    @State private var renameText = ""
    @State private var scrollTarget: UUID?

    private var session: SessionRecord? {
        pipeline.archive.sessions.first { $0.id == sessionID }
    }

    var body: some View {
        ScrollViewReader { proxy in
            list(proxy: proxy)
        }
    }

    private func list(proxy: ScrollViewProxy) -> some View {
        List {
            if let session {
                if let fileName = session.audioFileName {
                    Section {
                        PlaybackBar(url: SessionArchive.recordingURL(fileName: fileName))
                            .disabled(pipeline.isRunning)
                    } header: {
                        Text("Recording")
                    } footer: {
                        if let size = recordingSize(fileName) {
                            Text(size)
                        }
                    }
                }

                if let summary = session.summary {
                    Section("Summary") {
                        Text(summary)
                            .font(.callout)
                    }
                }

                if let notes = session.chunkNotes, notes.count > 1 {
                    Section("Outline") {
                        ForEach(notes) { note in
                            Button {
                                if let anchor = note.anchorEntryID {
                                    scrollTarget = anchor
                                }
                            } label: {
                                HStack {
                                    Text(note.headline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(note.startedAt, style: .time)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if !suggestions.isEmpty {
                    Section("Suggested hotwords") {
                        ForEach(suggestions, id: \.term) { suggestion in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(suggestion.term)
                                    if !suggestion.note.isEmpty {
                                        Text(suggestion.note)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button("Add") {
                                    pipeline.hotwords.add(
                                        Hotword(term: suggestion.term, note: suggestion.note))
                                    suggestions.removeAll { $0.term == suggestion.term }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }

                Section("Transcript") {
                    ForEach(transcriptBlocks(session), id: \.0) { block in
                        VStack(alignment: .leading, spacing: 6) {
                            if let label = block.1 {
                                Button {
                                    startRename(block.2)
                                } label: {
                                    Label(label, systemImage: "person")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tint)
                                }
                            }
                            ForEach(block.3) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.sourceText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let translation = entry.translation {
                                        Text(translation)
                                    }
                                }
                                .id(entry.id)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                if let actionError {
                    Section {
                        Text(actionError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle(session.map { Text($0.startedAt, style: .date) } ?? Text("Session"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let session {
                    ShareLink(item: session.markdown(), preview: SharePreview(session.title))
                }
                Menu {
                    Button {
                        summarize()
                    } label: {
                        Label(session?.summary == nil ? "Summarize" : "Re-summarize",
                              systemImage: "sparkles")
                    }
                    .disabled(summarizing)
                    Button {
                        suggestHotwords()
                    } label: {
                        Label("Suggest hotwords", systemImage: "character.magnify")
                    }
                    .disabled(suggesting)
                } label: {
                    if let progress = summarizeProgress, progress.total > 1 {
                        Text("\(progress.done)/\(progress.total)")
                            .font(.caption.monospacedDigit())
                    } else if summarizing || suggesting {
                        ProgressView()
                    } else {
                        Image(systemName: "wand.and.stars")
                    }
                }
            }
        }
        .alert("Rename speaker", isPresented: .init(
            get: { renamingSlot != nil },
            set: { if !$0 { renamingSlot = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if var session, let slot = renamingSlot {
                    session.speakerNames[slot] = renameText.isEmpty ? nil : renameText
                    pipeline.archive.update(session)
                }
                renamingSlot = nil
            }
            Button("Cancel", role: .cancel) { renamingSlot = nil }
        }
        .onChange(of: scrollTarget) {
            guard let target = scrollTarget else { return }
            withAnimation { proxy.scrollTo(target, anchor: .top) }
            scrollTarget = nil
        }
    }

    /// (block id, speaker label, slot, entries) grouped by consecutive speaker.
    private func transcriptBlocks(
        _ session: SessionRecord
    ) -> [(UUID, String?, Int, [SessionRecord.Entry])] {
        var blocks: [(UUID, String?, Int, [SessionRecord.Entry])] = []
        for entry in session.entries {
            if var last = blocks.last,
               entry.speaker == nil || entry.speaker == last.2 {
                last.3.append(entry)
                blocks[blocks.count - 1] = last
            } else {
                blocks.append((
                    entry.id,
                    session.speakerLabel(entry.speaker),
                    entry.speaker ?? -1,
                    [entry]))
            }
        }
        return blocks
    }

    private func recordingSize(_ fileName: String) -> String? {
        let url = SessionArchive.recordingURL(fileName: fileName)
        guard let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func startRename(_ slot: Int) {
        guard slot >= 0 else { return }
        renameText = session?.speakerNames[slot] ?? ""
        renamingSlot = slot
    }

    private func summarize() {
        guard let session else { return }
        summarizing = true
        actionError = nil
        Task {
            defer {
                summarizing = false
                summarizeProgress = nil
            }
            do {
                // Summaries are for the reader: the device language wins,
                // with the session's target language as fallback.
                let language = AppLanguage.devicePreferred
                    ?? session.entries.last?.direction.target ?? .english
                let engine = SummaryEngine(llm: pipeline.llm)
                let result = try await engine.summarize(session, in: language) { done, total in
                    summarizeProgress = (done, total)
                }
                var updated = session
                updated.summary = result.summary
                updated.chunkNotes = result.notes
                // Full coverage now: future re-summarize is reduce-only.
                updated.liveNotesEndEntryID = session.entries.last?.id
                pipeline.archive.update(updated)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func suggestHotwords() {
        guard let session else { return }
        suggesting = true
        actionError = nil
        Task {
            defer { suggesting = false }
            do {
                try await pipeline.llm.load()
                let builder = PromptBuilder()
                let prompt = builder.hotwordSuggestionPrompt(
                    transcript: session.plainTranscript())
                let raw = try await pipeline.llm.generate(
                    system: prompt.system, user: prompt.user, maxTokens: 200)
                let known = Set(pipeline.hotwords.hotwords.map(\.term))
                suggestions = builder.parseHotwordSuggestions(raw)
                    .filter { !known.contains($0.term) }
                if suggestions.isEmpty {
                    actionError = "No new terms found."
                }
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}
