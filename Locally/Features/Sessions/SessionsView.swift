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
    @State private var highlightedBlockID: UUID?

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
                        SummaryTextView(summary: summary)
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
                        transcriptBlockView(block)
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
            guard let target = scrollTarget, let session else { return }
            // List only registers row ids with the scroll proxy, so jump to
            // the transcript BLOCK containing the anchor entry, not the
            // entry's nested id (which scrollTo can't reach).
            let blockID = transcriptBlocks(session).first {
                $0.3.contains { $0.id == target }
            }?.0
            withAnimation { proxy.scrollTo(blockID ?? target, anchor: .top) }
            scrollTarget = nil
            // Flash the block so the eye lands on the right spot.
            highlightedBlockID = blockID
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation { highlightedBlockID = nil }
            }
        }
    }

    private func transcriptBlockView(
        _ block: (UUID, String?, Int, [SessionRecord.Entry])
    ) -> some View {
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
        .listRowBackground(
            block.0 == highlightedBlockID
                ? Color.accentColor.opacity(0.14) : nil)
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

/// Renders the plain-text summary (overview paragraph + "• " lines) with
/// real typography: paragraphs read as prose, bullets get a hanging indent
/// and breathing room, instead of one undifferentiated text blob.
struct SummaryTextView: View {
    let summary: String

    enum Part: Equatable {
        case paragraph(String)
        case bullet(String)
    }

    /// Small models vary the bullet glyph; accept the common ones.
    /// nonisolated: pure string logic, also exercised off-main in tests.
    nonisolated static func parse(_ summary: String) -> [Part] {
        let markers = ["•", "・", "·", "●", "-", "*"]
        var parts: [Part] = []
        var paragraph: [String] = []

        func closeParagraph() {
            if !paragraph.isEmpty {
                parts.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }

        for rawLine in summary.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                closeParagraph()
            } else if let marker = markers.first(where: { line.hasPrefix($0) }) {
                closeParagraph()
                let text = line.dropFirst(marker.count)
                    .trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { parts.append(.bullet(text)) }
            } else {
                paragraph.append(line)
            }
        }
        closeParagraph()
        return parts
    }

    var body: some View {
        let parts = Self.parse(summary)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                switch part {
                case .paragraph(let text):
                    Text(text)
                        .font(.callout)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Circle()
                            .fill(.tint)
                            .frame(width: 5, height: 5)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                        Text(text)
                            .font(.callout)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .textSelection(.enabled)
    }
}
