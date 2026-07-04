import SwiftUI
import UniformTypeIdentifiers

/// Saved sessions: list with live background-job progress, search,
/// multi-select batch actions, transcript detail, on-device summary,
/// Markdown export, speaker renaming, and hotword suggestions.
struct SessionsView: View {
    @Bindable var pipeline: CaptionPipeline
    @State private var pickingFile = false
    @State private var importURL: URL?
    @State private var searchQuery = ""
    @State private var searchIndex = SessionSearchIndex()
    @State private var isSelecting = false
    @State private var selection = Set<UUID>()
    @State private var confirmBatchDelete = false
    @State private var batchAlert: String?
    /// Briefly highlighted row: a session just arrived or just finished
    /// its background job.
    @State private var flashedSessionID: UUID?

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchMatches: [SessionSearch.Match] {
        searchIndex.matches(in: pipeline.archive.sessions, query: searchQuery)
    }

    private var isEditing: Bool { isSelecting }

    private var selectedSessions: [SessionRecord] {
        pipeline.archive.sessions.filter { selection.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                if trimmedQuery.isEmpty {
                    ForEach(pipeline.archive.sessions) { session in
                        row(session)
                            // Multi-select shows selection circles only —
                            // without this, onDelete adds the red minus
                            // controls next to them in edit mode.
                            .deleteDisabled(isEditing)
                            .listRowBackground(
                                session.id == flashedSessionID
                                    ? Color.accentColor.opacity(0.16) : nil)
                    }
                    // Delete only outside search: ForEach offsets map to the
                    // archive's array order, which a filtered list breaks.
                    .onDelete { offsets in
                        deleteSessions(ids: Set(
                            offsets.map { pipeline.archive.sessions[$0].id }))
                    }
                } else {
                    ForEach(searchMatches) { match in
                        if let session = pipeline.archive.sessions
                            .first(where: { $0.id == match.sessionID }) {
                            NavigationLink {
                                SessionDetailView(
                                    pipeline: pipeline,
                                    sessionID: match.sessionID,
                                    initialScrollEntryID: match.firstEntryID)
                            } label: {
                                searchRowLabel(session, match: match)
                            }
                        }
                    }
                }
            }
            .loqiSessionEditMode(isSelecting: $isSelecting)
            .searchable(text: $searchQuery, prompt: Text("Search sessions"))
            .tabHeaderTitle("Sessions")
            .toolbar { toolbarContent }
            // The batch actions live in an explicit bottom inset: on iOS 26
            // the floating tab bar and bottom-docked search own the
            // .bottomBar toolbar region, and items placed there never show.
#if os(iOS)
            .toolbar(isEditing ? .hidden : .automatic, for: .tabBar)
#endif
            .safeAreaInset(edge: .bottom) {
                if isEditing {
                    batchActionBar
                }
            }
            .fileImporter(
                isPresented: $pickingFile,
                allowedContentTypes: [.audio, .movie]
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
                } else if !trimmedQuery.isEmpty, searchMatches.isEmpty {
                    ContentUnavailableView.search(text: trimmedQuery)
                }
            }
            .confirmationDialog(
                "Delete \(selection.count) sessions?",
                isPresented: $confirmBatchDelete,
                titleVisibility: .visible
            ) {
                Button("Delete recording, transcript and notes", role: .destructive) {
                    deleteSessions(ids: selection)
                    withAnimation { isSelecting = false }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This can't be undone.")
            }
            .alert("Can't re-transcribe", isPresented: .init(
                get: { batchAlert != nil },
                set: { if !$0 { batchAlert = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(batchAlert ?? "")
            }
            // Flash fresh arrivals: a new row (live save, import placeholder)
            // or a background import completing on an existing row.
            .onChange(of: pipeline.archive.sessions.map(\.id)) { old, new in
                guard let fresh = new.first(where: { !old.contains($0) }) else { return }
                flash(fresh)
            }
            .onChange(of: pipeline.jobs.lastCompleted) { _, completed in
                if let completed { flash(completed.id) }
            }
            // Search and edit mode don't mix: the filtered rows carry match
            // ids, not session ids.
            .onChange(of: trimmedQuery) { _, query in
                if !query.isEmpty, isEditing {
                    isSelecting = false
                    selection.removeAll()
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isEditing {
#if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    withAnimation {
                        isSelecting = false
                        selection.removeAll()
                    }
                }
            }
#else
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    withAnimation {
                        isSelecting = false
                        selection.removeAll()
                    }
                }
            }
#endif
        } else {
#if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                if !pipeline.archive.sessions.isEmpty, trimmedQuery.isEmpty {
                    Button("Select", systemImage: "checkmark.circle") {
                        withAnimation { isSelecting = true }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Import audio", systemImage: "square.and.arrow.down") {
                    pickingFile = true
                }
                .disabled(pipeline.isRunning)
            }
#else
            ToolbarItem(placement: .primaryAction) {
                if !pipeline.archive.sessions.isEmpty, trimmedQuery.isEmpty {
                    Button("Select", systemImage: "checkmark.circle") {
                        withAnimation { isSelecting = true }
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Import audio", systemImage: "square.and.arrow.down") {
                    pickingFile = true
                }
                .disabled(pipeline.isRunning)
            }
#endif
        }
    }

    /// Batch actions over the current selection, shown while editing.
    private var batchActionBar: some View {
        HStack {
            Button("Re-transcribe (\(selection.count))") {
                batchRetranscribe()
            }
            Spacer()
            ShareLink(
                "Export (\(selection.count))",
                items: selectedSessions.map(SessionMarkdownDocument.init)
            ) { document in
                SharePreview(document.record.title)
            }
            Spacer()
            Button("Delete (\(selection.count))", role: .destructive) {
                confirmBatchDelete = true
            }
        }
        .disabled(selection.isEmpty)
        .font(.subheadline)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    /// Row shell: navigable normally, a bare selectable label in edit mode.
    @ViewBuilder
    private func row(_ session: SessionRecord) -> some View {
        if isEditing {
            rowContent(session)
        } else {
            NavigationLink {
                SessionDetailView(pipeline: pipeline, sessionID: session.id)
            } label: {
                rowContent(session)
            }
            .contextMenu {
                if pipeline.jobs.isBusy(session.id) {
                    Button("Cancel processing", systemImage: "xmark.circle", role: .destructive) {
                        pipeline.jobs.cancel(session.id)
                    }
                }
            }
        }
    }

    private func rowContent(_ session: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sessionRowLabel(session)
            SessionRowStatus(jobs: pipeline.jobs, sessionID: session.id)
        }
    }

    /// Title, then the facts a capture archive lives on: when, how long,
    /// and whether audio / a summary exist. (Raw entry counts told users
    /// nothing.)
    private func sessionRowLabel(_ session: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if session.unseen == true {
                    Circle()
                        .fill(.tint)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("New")
                }
                Text(session.title)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(session.startedAt, style: .date)
                Text(session.startedAt, style: .time)
                Text("· \(Self.durationText(session.duration))")
                if session.audioFileName != nil {
                    Image(systemName: "waveform")
                        .accessibilityLabel("Has recording")
                }
                if session.summary != nil {
                    Image(systemName: "doc.text")
                        .accessibilityLabel("Has summary")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// "3:25" under an hour, "1:02:09" above.
    private static func durationText(_ duration: TimeInterval) -> String {
        Duration.seconds(duration).formatted(.time(
            pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    private func searchRowLabel(
        _ session: SessionRecord, match: SessionSearch.Match
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                sessionRowLabel(session)
                Text(match.snippet)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Text("\(match.matchCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
    }

    // MARK: Actions

    /// Single delete path for swipe and batch: a running job must stop
    /// before its record (and files) disappear under it.
    private func deleteSessions(ids: Set<UUID>) {
        for id in ids {
            pipeline.jobs.cancel(id)
            pipeline.hotwords.discardSuggestions(forSession: id)
            pipeline.archive.delete(id: id)
        }
        selection.subtract(ids)
    }

    private func batchRetranscribe() {
        let llmEnabled = UserDefaults.standard.object(forKey: "llm.enabled") == nil
            || UserDefaults.standard.bool(forKey: "llm.enabled")
        guard llmEnabled else {
            batchAlert = String(localized: "AI features are turned off in Settings.")
            return
        }
        let eligible = selectedSessions.filter(SessionRetranscriber.canRetranscribe)
        guard !eligible.isEmpty else {
            batchAlert = String(localized:
                "None of the selected sessions has a saved recording to re-transcribe.")
            return
        }
        guard LLMService.isDownloaded(model: ModelCatalog.current) else {
            batchAlert = String(localized:
                "The AI model isn't downloaded yet. Open a session and use Re-transcribe & summarize once to download it.")
            return
        }
        // Each session keeps its own summary shape; the queue serializes.
        for session in eligible {
            pipeline.jobs.enqueueRetranscribe(
                ids: [session.id],
                style: session.resolvedSummaryStyle,
                length: session.resolvedSummaryLength)
        }
        withAnimation {
            isSelecting = false
            selection.removeAll()
        }
    }

    private func flash(_ id: UUID) {
        withAnimation(.easeIn(duration: 0.25)) { flashedSessionID = id }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if flashedSessionID == id {
                withAnimation(.easeOut(duration: 0.6)) { flashedSessionID = nil }
            }
        }
    }
}

private extension View {
    #if os(iOS)
    /// One-way binding: the List can read edit mode but can't reset it
    /// behind our back (the tab-bar hide transition was causing that).
    func loqiSessionEditMode(isSelecting: Binding<Bool>) -> some View {
        environment(
            \.editMode,
            Binding(
                get: { isSelecting.wrappedValue ? .active : .inactive },
                set: { isSelecting.wrappedValue = ($0 == .active) }
            )
        )
    }
    #else
    func loqiSessionEditMode(isSelecting: Binding<Bool>) -> some View {
        self
    }
    #endif
}

/// Live job status under a session row. A separate view so the per-tick
/// `activities` reads re-evaluate only the few busy rows, not the list.
private struct SessionRowStatus: View {
    let jobs: SummaryJobCenter
    let sessionID: UUID

    var body: some View {
        if let activity = jobs.activity(for: sessionID) {
            if case .queuedRetranscribe = activity {
                Label("Waiting to re-transcribe…", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .pausedForRecording = activity {
                Label("Paused — recording in progress", systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .pausedForBackground = activity {
                Label("Paused — open Loqi to continue", systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let info = Self.info(for: activity)
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: info.fraction)
                    Text(caption(info))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        } else if let error = jobs.error(for: sessionID) {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private static func info(
        for activity: SummaryJobCenter.Activity
    ) -> (label: String, fraction: Double?) {
        switch activity {
        case .downloadingModel(let f):
            (String(localized: "Downloading AI model…"), f)
        case .summarizing(let done, let total):
            (String(localized: "Summarizing…"),
             total > 1 ? Double(done) / Double(total) : nil)
        case .retranscribing(.transcribing(let f)):
            (String(localized: "Re-transcribing…"), f)
        case .retranscribing(.cleaningUpTranscript(let f)):
            (String(localized: "Cleaning up transcript…"), f)
        case .retranscribing(.identifyingSpeakers(let f)):
            (String(localized: "Identifying speakers…"), f)
        case .retranscribing(.translating(let f)):
            (String(localized: "Translating…"), f)
        case .importing(.transcribing(let f)):
            (String(localized: "Transcribing…"), f)
        case .importing(.fetchingSpeakerModel(let f)):
            (String(localized: "Downloading speaker model…"), f)
        case .importing(.identifyingSpeakers(let f)):
            (String(localized: "Identifying speakers…"), f)
        case .importing(.translating(let f)):
            (String(localized: "Translating…"), f)
        case .queuedRetranscribe:
            (String(localized: "Waiting to re-transcribe…"), nil)
        case .pausedForRecording:
            (String(localized: "Paused — recording in progress"), nil)
        case .pausedForBackground:
            (String(localized: "Paused — open Loqi to continue"), nil)
        }
    }

    /// "Transcribing… · 37% · ~4 min left" — percent and remaining only
    /// when known.
    private func caption(_ info: (label: String, fraction: Double?)) -> String {
        var parts = [info.label]
        if let fraction = info.fraction {
            parts.append(fraction.formatted(.percent.precision(.fractionLength(0))))
        }
        if let remaining = jobs.remaining[sessionID] {
            parts.append(ProcessingETA.text(remaining: remaining))
        }
        return parts.joined(separator: " · ")
    }
}

/// Wraps a session so ShareLink writes a correctly named .md file at share
/// time. Each file lands in its own temp subdirectory — two sessions can
/// share a title, and a fixed path would overwrite one mid-share.
private struct SessionMarkdownDocument: Transferable {
    let record: SessionRecord

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { document in
            let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let name = document.record.title
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            let url = directory.appending(path: "\(name).md")
            try Data(document.record.markdown().utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}
