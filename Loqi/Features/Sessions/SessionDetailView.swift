import PhotosUI
import SwiftUI

/// A saved session: playback, summary (editable), timeline, hotword
/// suggestions, and transcript. Pushed from the Sessions list, and from the
/// Record tab right after a recording (with `autoSummarizeStyle` set).
///
/// Summarize/re-transcribe run in the pipeline's SummaryJobCenter, not in
/// view state: progress survives navigation and re-entry, and a session
/// can never run two jobs at once.
struct SessionDetailView: View {
    @Bindable var pipeline: CaptionPipeline
    let sessionID: UUID
    /// Entry to jump to once the transcript renders (search-result taps).
    var initialScrollEntryID: UUID? = nil
    /// When set, the view was pushed right after recording: summary
    /// generation starts immediately, no manual Summarize needed.
    var autoSummarizeStyle: SummaryStyle? = nil
    var autoSummarizeLength: SummaryLength? = nil

    @State private var suggesting = false
    @State private var suggestions: [HotwordSuggestion] = []
    @State private var actionError: String?
    /// Neutral, self-clearing line for blocked actions (gray, not red).
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?
    @State private var renamingSlot: Int?
    @State private var renameText = ""
    @State private var renamingTitle = false
    @State private var titleDraft = ""
    @State private var scrollTarget: UUID?
    @State private var highlightedBlockID: UUID?
    @State private var isEditingSummary = false
    @State private var summaryDraft = ""
    @State private var confirmRegenerate = false
    @State private var showingRetranscribeOptions = false
    @State private var showingIdentifySpeakers = false
    @State private var timelineExpanded = false
    @State private var confirmDeleteAudio = false
    @State private var showingChat = false
    @State private var showingLanguages = false
    /// A style/length change awaiting the "replace edited summary?" confirm.
    @State private var pendingRegenerate: PendingRegenerate?
    @State private var autoStarted = false
    /// Shared with PlaybackBar so tapping a transcript line can seek.
    @State private var playback = AudioPlaybackController()
    @State private var viewingAttachment: SessionRecord.Attachment?
    @State private var showingCamera = false
    @State private var showingPhotoLibrary = false
    @State private var photoItem: PhotosPickerItem?
    /// AI action waiting on the user's one-time model-download consent.
    @State private var pendingDownload: DownloadAction?
    /// Last style the user picked anywhere — the default for new sessions.
    @AppStorage("summary.defaultStyle") private var defaultStyleRaw
        = SummaryStyle.meeting.rawValue
    @AppStorage("summary.defaultLength") private var defaultLengthRaw
        = SummaryLength.standard.rawValue
    @AppStorage("record.autoSuggest") private var autoSuggest = true
    @AppStorage("summary.autoPostProcessNewRecordings")
    private var autoPostProcessNewRecordings = false
    /// Diagnostic: render each entry's pre-cleanup ASR text (`rawSourceText`)
    /// under the displayed line when they differ, to tell whether the
    /// LFM2.5 cleanup dropped words vs the decoder never producing them.
    @AppStorage("debug.showOriginalRecognition")
    private var showOriginalRecognition = false

    /// What to run once the user consents to downloading the model.
    private enum DownloadAction: Equatable {
        case summarize(SummaryStyle, SummaryLength, suggestVocabulary: Bool)
        case postProcessNewRecording(SummaryStyle, SummaryLength, suggestVocabulary: Bool)
        // Carries the sheet's picks so a download detour doesn't lose them.
        case retranscribe(MicSensitivity, backend: OfflineTranscriber.Backend?)
        case suggestHotwords
    }

    private var session: SessionRecord? {
        pipeline.archive.sessions.first { $0.id == sessionID }
    }

    private var jobActivity: SummaryJobCenter.Activity? {
        pipeline.jobs.activity(for: sessionID)
    }

    private var jobRunning: Bool { jobActivity != nil }

    private var selectedStyle: SummaryStyle {
        SummaryStyle.effective(
            storedRaw: session?.summaryStyle,
            hasSummary: session?.summary != nil,
            defaultRaw: defaultStyleRaw)
    }

    private var selectedLength: SummaryLength {
        SummaryLength.effective(
            storedRaw: session?.summaryLength,
            hasSummary: session?.summary != nil,
            defaultRaw: defaultLengthRaw)
    }

    var body: some View {
        ScrollViewReader { proxy in
            list(proxy: proxy)
        }
    }

    /// The List plus navigation chrome and presentation surfaces. Split
    /// from the dialog/task layers so no single expression overwhelms the
    /// type checker.
    private var decoratedList: some View {
        List {
            if let session {
                recordingSection(session)
                speakerRetrySection(session)
                // Whenever a job runs — gating on `summary == nil` hid the
                // entire ASR half of a re-transcribe (and all of a
                // re-summarize) on any session that already had a summary.
                if jobRunning {
                    Section {
                        jobProgressRow
                    } header: {
                        // Transcript-producing phases aren't "Summary" work.
                        switch jobActivity {
                        case .importing, .retranscribing, .preparing,
                             .queuedRetranscribe, .downloadingSpeakerModel:
                            Text("Processing")
                        default:
                            Text("Summary")
                        }
                    }
                }
                summarySection(session)
                timelineSection(session)
                suggestionsSection
                photosSection(session)
                if !session.entries.isEmpty {
                    Section("Transcript") {
                        ForEach(transcriptBlocks(session), id: \.0) { block in
                            transcriptBlockView(block)
                        }
                    }
                }
                feedbackSection
            }
        }
        .navigationTitle(session.map { Text($0.title) } ?? Text("Session"))
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        // The playback controller belongs to the whole detail screen, not
        // the bar's List row — a row's onDisappear fires on mere scrolling,
        // which used to kill audio mid-listen.
        .onDisappear { playback.stop() }
        .toolbar {
#if os(iOS)
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Ask this session", systemImage: "bubble.left.and.text.bubble.right") {
                    showingChat = true
                }
                if let session {
                    exportMenu(session)
                }
                actionsMenu
            }
#else
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Ask this session", systemImage: "bubble.left.and.text.bubble.right") {
                    showingChat = true
                }
                if let session {
                    exportMenu(session)
                }
                actionsMenu
            }
#endif
        }
        .sheet(isPresented: $showingChat) {
            SessionChatSheet(pipeline: pipeline, sessionID: sessionID)
        }
        .sheet(isPresented: $showingLanguages) {
            SessionLanguagesSheet(pipeline: pipeline, sessionID: sessionID)
        }
        .sheet(isPresented: $showingRetranscribeOptions) {
            RetranscribeOptionsSheet(pipeline: pipeline, sessionID: sessionID) { sensitivity, backend in
                requestRetranscribe(sensitivity: sensitivity, backend: backend)
            }
        }
        .sheet(isPresented: $showingIdentifySpeakers) {
            IdentifySpeakersSheet(pipeline: pipeline, sessionID: sessionID)
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCaptureView { image in
                pipeline.attachImage(image, to: sessionID)
            }
        }
        #endif
        .photosPicker(
            isPresented: $showingPhotoLibrary,
            selection: $photoItem,
            matching: .images)
        .onChange(of: photoItem) {
            guard let item = photoItem else { return }
            photoItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    pipeline.attachImage(image, to: sessionID)
                }
            }
        }
#if os(iOS)
        .fullScreenCover(item: $viewingAttachment) { attachment in
            AttachmentViewer(
                attachment: attachment,
                onSaveCaption: { saveCaption($0, for: attachment) },
                onDelete: { deleteAttachment(attachment) })
        }
#else
        .sheet(item: $viewingAttachment) { attachment in
            AttachmentViewer(
                attachment: attachment,
                onSaveCaption: { saveCaption($0, for: attachment) },
                onDelete: { deleteAttachment(attachment) })
        }
#endif
    }

    /// Alerts and confirmation dialogs layered over the decorated list.
    private var dialogHost: some View {
        decoratedList
        .alert("Rename session", isPresented: $renamingTitle) {
            TextField("Title", text: $titleDraft)
            Button("Save") {
                if var session {
                    let text = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        session.titleText = text
                        session.titleEdited = true
                        pipeline.archive.update(session)
                    }
                }
                renamingTitle = false
            }
            Button("Cancel", role: .cancel) { renamingTitle = false }
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
                    // Names are vocabulary; the note stays English — notes
                    // are LLM prompt hints, not UI copy.
                    pipeline.hotwords.captureIfNew(term: renameText, note: "person name")
                }
                renamingSlot = nil
            }
            Button("Cancel", role: .cancel) { renamingSlot = nil }
        }
        .confirmationDialog(
            "Replace edited summary?",
            isPresented: $confirmRegenerate,
            titleVisibility: .visible
        ) {
            // Backs both the wand's Re-summarize (pending == nil, same
            // settings) and an inline style/length change (pending set).
            Button("Replace", role: .destructive) {
                if let pending = pendingRegenerate {
                    applySummaryPreferences(style: pending.style, length: pending.length)
                } else {
                    requestSummarize(style: selectedStyle, length: selectedLength)
                }
                pendingRegenerate = nil
            }
            Button("Cancel", role: .cancel) { pendingRegenerate = nil }
        } message: {
            Text("You edited this summary. Summarizing again will replace your changes.")
        }
        .confirmationDialog(
            "Delete this session's audio?",
            isPresented: $confirmDeleteAudio,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                pipeline.archive.discardAudio(for: sessionID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let fileName = session?.audioFileName,
               let bytes = SessionArchive.recordingSizeBytes(fileName: fileName) {
                Text("The transcript and summary are kept. Frees \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).")
            } else {
                Text("The transcript and summary are kept.")
            }
        }
        .confirmationDialog(
            "Download the AI model?",
            isPresented: .init(
                get: { pendingDownload != nil },
                set: { if !$0 { pendingDownload = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Download \(Self.modelSizeText) and continue") {
                if let action = pendingDownload {
                    runAfterDownloadConsent(action)
                }
                pendingDownload = nil
            }
            Button("Cancel", role: .cancel) { pendingDownload = nil }
        } message: {
            Text("Summaries, chat and suggestions run on a local AI model. It downloads once (\(Self.modelSizeText), Wi-Fi recommended) and everything stays on this device.")
        }
    }

    private func clearUnseen() {
        guard let session, session.unseen == true else { return }
        var seen = session
        seen.unseen = nil
        pipeline.archive.update(seen)
    }

    private func list(proxy: ScrollViewProxy) -> some View {
        dialogHost
        .task {
            // Opening the session clears its "new" dot in the list.
            clearUnseen()
        }
        // An import that COMPLETES while this screen is open stamps the
        // record unseen — the user just watched it finish, so clear the
        // dot again instead of flagging a session they've already seen.
        .onChange(of: session?.unseen) { clearUnseen() }
        .task {
            guard let style = autoSummarizeStyle, !autoStarted,
                  let session, session.summary == nil else { return }
            autoStarted = true
            requestAutoSummarize(
                style: style,
                length: autoSummarizeLength ?? selectedLength,
                suggestVocabulary: autoSuggest)
        }
        .task {
            guard let target = initialScrollEntryID else { return }
            // Let the List lay out its rows before asking the proxy to jump,
            // then reuse the timeline-tap machinery (block scroll + flash).
            try? await Task.sleep(for: .milliseconds(350))
            scrollTarget = target
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

    /// Progress row matching the job's current stage.
    @ViewBuilder
    private var jobProgressRow: some View {
        switch jobActivity {
        case .downloadingModel(let fraction):
            PercentProgressRow(label: "Downloading AI model…", fraction: fraction)
        case .retranscribing(.transcribing(let fraction)):
            PercentProgressRow(
                label: "Re-transcribing…", fraction: fraction, detail: remainingText)
        case .retranscribing(.cleaningUpTranscript(let fraction)):
            PercentProgressRow(
                label: "Cleaning up transcript…", fraction: fraction, detail: remainingText)
        case .retranscribing(.identifyingSpeakers(let fraction)):
            PercentProgressRow(
                label: "Identifying speakers…", fraction: fraction, detail: remainingText)
        case .retranscribing(.translating(let fraction)):
            PercentProgressRow(
                label: "Translating…", fraction: fraction, detail: remainingText)
        case .importing(.transcribing(let fraction)):
            PercentProgressRow(
                label: "Transcribing…", fraction: fraction, detail: remainingText)
        case .importing(.cleaningUpTranscript(let fraction)):
            PercentProgressRow(
                label: "Cleaning up transcript…", fraction: fraction, detail: remainingText)
        case .importing(.fetchingSpeakerModel(let fraction)):
            PercentProgressRow(
                label: "Downloading speaker model…", fraction: fraction,
                detail: remainingText)
        case .importing(.identifyingSpeakers(let fraction)):
            PercentProgressRow(
                label: "Identifying speakers…", fraction: fraction,
                detail: remainingText)
        case .importing(.translating(let fraction)):
            PercentProgressRow(
                label: "Translating…", fraction: fraction, detail: remainingText)
        case .downloadingSpeakerModel(let fraction):
            PercentProgressRow(
                label: "Downloading speaker model…", fraction: fraction,
                detail: remainingText)
        case .retranscribing(.coolingDown), .importing(.coolingDown):
            Label("Paused to cool down — resumes automatically",
                  systemImage: "thermometer.high")
                .foregroundStyle(.secondary)
        case .preparing:
            HStack(spacing: 8) {
                ProgressView()
                Text("Preparing…")
                    .foregroundStyle(.secondary)
            }
        case .queuedRetranscribe:
            Label(pipeline.jobs.finishingPreviousAttempt
                    ? "Finishing the previous attempt…"
                    : "Waiting to re-transcribe…",
                  systemImage: "clock")
                .foregroundStyle(.secondary)
        case .pausedForRecording:
            Label("Paused — recording in progress", systemImage: "pause.circle")
                .foregroundStyle(.secondary)
        case .pausedForBackground:
            Label("Paused — open Loqi to continue", systemImage: "pause.circle")
                .foregroundStyle(.secondary)
        case .summarizing(let done, let total) where total > 1:
            // Map chunks and stitched detail sections report real counts;
            // the last step is the reduce — one long generation with no
            // intermediate progress, so name it instead of parking a bar.
            if done >= total - 1 {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Finalizing summary…")
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView(value: Double(done), total: Double(total)) {
                    Text("Summarizing…")
                }
            }
        default:
            HStack(spacing: 8) {
                ProgressView()
                Text("Summarizing…")
                    .foregroundStyle(.secondary)
            }
        }
        if jobRunning {
            // The list row's long-press menu was the app's ONLY cancel;
            // the session's own screen needs one too.
            Button("Cancel processing", systemImage: "xmark.circle", role: .destructive) {
                pipeline.jobs.cancel(sessionID)
            }
            .font(.footnote)
        }
    }

    /// "~4 min left" while the job center has a usable rate; nil hides it.
    private var remainingText: String? {
        pipeline.jobs.remaining[sessionID].map { ProcessingETA.text(remaining: $0) }
    }

    /// Toolbar wand: compact progress while a job runs, the wand otherwise.
    @ViewBuilder
    private var wandLabel: some View {
        switch jobActivity {
        case .retranscribing(.transcribing(let fraction)),
             .retranscribing(.identifyingSpeakers(let fraction)),
             .downloadingModel(let fraction):
            Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                .font(.caption.monospacedDigit())
        case .summarizing(let done, let total) where total > 1:
            Text("\(done)/\(total)")
                .font(.caption.monospacedDigit())
        case .queuedRetranscribe, .preparing:
            // Parked, not working — a spinner here claimed active work.
            Image(systemName: "clock")
                .font(.caption)
        case .pausedForRecording, .pausedForBackground:
            Image(systemName: "pause.circle")
                .font(.caption)
        case .retranscribing(.coolingDown), .importing(.coolingDown):
            Image(systemName: "thermometer.high")
                .font(.caption)
        case .some:
            ProgressView()
        case .none:
            if suggesting {
                ProgressView()
            } else {
                Image(systemName: "wand.and.stars")
            }
        }
    }

    private func exportMenu(_ session: SessionRecord) -> some View {
        Menu {
            ShareLink(item: session.markdown(), preview: SharePreview(session.title)) {
                Label("Markdown", systemImage: "doc.text")
            }
            ShareLink(
                item: subtitleDocument(for: session, format: .srt, bilingual: false),
                preview: SharePreview(session.title)
            ) {
                Label("Subtitles (SRT)", systemImage: "captions.bubble")
            }
            if session.entries.contains(where: { $0.translation?.isEmpty == false }) {
                ShareLink(
                    item: subtitleDocument(for: session, format: .srt, bilingual: true),
                    preview: SharePreview(session.title)
                ) {
                    Label("Subtitles (SRT, bilingual)", systemImage: "captions.bubble.fill")
                }
            }
            ShareLink(
                item: subtitleDocument(for: session, format: .vtt, bilingual: false),
                preview: SharePreview(session.title)
            ) {
                Label("Subtitles (WebVTT)", systemImage: "captions.bubble")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
    }

    private var actionsMenu: some View {
        Menu {
            // Grouped by intent so the menu reads as three short clusters
            // instead of one flat wall: (1) produce the summary — the cheap
            // re-summarize first, then the expensive source-level redos;
            // (2) adjust how it's made; (3) edit this session. Niche tools
            // sit in their own trailing group so they don't compete with
            // the everyday actions.
            Section {
                Button {
                    if blockedByRecording() { return }
                    if session?.summaryEdited == true {
                        pendingRegenerate = nil   // same settings; not a style change
                        confirmRegenerate = true
                    } else {
                        requestSummarize(style: selectedStyle, length: selectedLength)
                    }
                } label: {
                    Label(session?.summary == nil ? "Summarize" : "Re-summarize",
                          systemImage: "sparkles")
                }
                .disabled(jobRunning || isEditingSummary)
                if let session, SessionRetranscriber.canRetranscribe(session) {
                    // Tappable during a recording so the tap shows WHY it's
                    // blocked (a bare grey button explained nothing); disabled
                    // only for states the progress/edit UI already explains.
                    Button {
                        if blockedByRecording() { return }
                        showingRetranscribeOptions = true
                    } label: {
                        Label("Re-transcribe & summarize",
                              systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    }
                    .disabled(jobRunning || isEditingSummary)
                    // Run/redo diarization alone: labels a session that never
                    // got them, or re-clusters one that split badly — without
                    // paying for a re-transcribe.
                    Button {
                        if blockedByRecording() { return }
                        showingIdentifySpeakers = true
                    } label: {
                        Label("Identify speakers", systemImage: "person.2.wave.2")
                    }
                    .disabled(jobRunning || isEditingSummary)
                }
            }
            Section {
                // Inline style/length pickers: choosing one regenerates in
                // that style in a single gesture (SwiftUI renders a Picker
                // in a menu as a checkmarked submenu). Replaces the old
                // "Summary options" sheet round-trip. Selecting the current
                // value is a no-op — the "Re-summarize" button above is the
                // same-settings redo.
                Picker("Summary style", selection: Binding(
                    get: { selectedStyle },
                    set: { regenerateSummary(style: $0, length: selectedLength) })
                ) {
                    ForEach(SummaryStyle.allCases) { style in
                        Label(style.displayName, systemImage: style.symbolName).tag(style)
                    }
                }
                .disabled(jobRunning || isEditingSummary)
                Picker("Summary length", selection: Binding(
                    get: { selectedLength },
                    set: { regenerateSummary(style: selectedStyle, length: $0) })
                ) {
                    ForEach(SummaryLength.allCases) { length in
                        Label(length.displayName, systemImage: length.symbolName).tag(length)
                    }
                }
                .disabled(jobRunning || isEditingSummary)
                if session != nil {
                    Button {
                        if blockedByRecording() { return }
                        showingLanguages = true
                    } label: {
                        Label("Languages", systemImage: "globe")
                    }
                }
            }
            Section {
                Button {
                    titleDraft = session?.title ?? ""
                    renamingTitle = true
                } label: {
                    Label("Rename session", systemImage: "pencil")
                }
                Menu {
                    #if os(iOS)
                    Button("Take photo", systemImage: "camera") {
                        showingCamera = true
                    }
                    #endif
                    Button("Photo library", systemImage: "photo.on.rectangle") {
                        showingPhotoLibrary = true
                    }
                } label: {
                    Label("Add photo", systemImage: "photo.badge.plus")
                }
            }
            Section {
                Button {
                    requestSuggestHotwords()
                } label: {
                    Label("Suggest hotwords", systemImage: "character.magnify")
                }
                .disabled(suggesting || jobRunning)
            }
        } label: {
            wandLabel
        }
    }

    @ViewBuilder
    private func recordingSection(_ session: SessionRecord) -> some View {
        if let fileName = session.audioFileName {
            Section {
                PlaybackBar(
                    url: SessionArchive.recordingURL(fileName: fileName),
                    controller: playback)
                    .disabled(pipeline.isRunning)
            } header: {
                HStack {
                    Text("Recording")
                    Spacer()
                    Button("Delete") { confirmDeleteAudio = true }
                        .font(.footnote)
                        .textCase(nil)
                }
            } footer: {
                if let size = recordingSize(fileName) {
                    Text(size)
                }
            }
        }
    }

    /// Shown when speaker separation was requested but the diarizer failed
    /// (e.g. the model couldn't download). The transcript is fine; this just
    /// offers an in-place retry. Hidden while any job runs for this session.
    @ViewBuilder
    private func speakerRetrySection(_ session: SessionRecord) -> some View {
        if session.speakerSeparationFailed == true, !jobRunning {
            Section {
                Label(
                    "Speaker separation didn't finish — the transcript is complete, but voices aren't labeled.",
                    systemImage: "person.2.slash")
                    .font(.footnote)
                if SessionRetranscriber.canRetranscribe(session) {
                    Button("Retry speaker separation") {
                        pipeline.jobs.retryDiarization(sessionID: sessionID)
                    }
                    .disabled(pipeline.isRunning)
                }
            }
        }
    }

    @ViewBuilder
    private func summarySection(_ session: SessionRecord) -> some View {
        if let summary = session.summary {
            Section {
                if isEditingSummary {
                    TextEditor(text: $summaryDraft)
                        .font(.callout)
                        .frame(minHeight: 180)
                } else {
                    SummaryTextView(summary: summary)
                }
            } header: {
                HStack {
                    Text("Summary")
                    Spacer()
                    Button(isEditingSummary ? "Done" : "Edit") {
                        if isEditingSummary {
                            saveSummaryEdit()
                        } else {
                            summaryDraft = summary
                            isEditingSummary = true
                        }
                    }
                    .font(.footnote)
                    .textCase(nil)
                    .disabled(jobRunning)
                }
            }
        }
    }

    @ViewBuilder
    private func timelineSection(_ session: SessionRecord) -> some View {
        if let notes = session.chunkNotes, notes.count > 1 {
            Section {
                DisclosureGroup(isExpanded: $timelineExpanded) {
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
                } label: {
                    Text("Timeline")
                }
            }
        }
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        if !suggestions.isEmpty {
            Section("Suggested hotwords") {
                ForEach(suggestions, id: \.term) { suggestion in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(suggestion.term)
                            let detail = suggestionDetail(suggestion)
                            if !detail.isEmpty {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Add") {
                            pipeline.hotwords.add(
                                Hotword(
                                    term: suggestion.term,
                                    renderings: suggestion.renderings,
                                    note: suggestion.note))
                            suggestions.removeAll { $0.term == suggestion.term }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func photosSection(_ session: SessionRecord) -> some View {
        let photos = allAttachments(session)
        if !photos.isEmpty {
            Section("Photos") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(photos) { attachment in
                            AttachmentThumbnail(attachment: attachment)
                                .onTapGesture { viewingAttachment = attachment }
                        }
                    }
                }
            }
        }
    }

    /// Job/action errors in red; neutral notices (blocked actions) in gray.
    @ViewBuilder
    private var feedbackSection: some View {
        if let error = pipeline.jobs.error(for: sessionID) ?? actionError {
            Section {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        if let notice {
            Section {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
            // One row per PARAGRAPH (consecutive entries flowed together);
            // tap seeks to the paragraph's first entry.
            ForEach(TranscriptParagraphs.group(block.3), id: \.first?.id) { paragraph in
                let translations = paragraph.compactMap(\.translation)
                let raws = paragraph.map { $0.rawSourceText ?? $0.sourceText }
                VStack(alignment: .leading, spacing: 2) {
                    Text(TranscriptParagraphs.joined(paragraph.map(\.sourceText)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // Diagnostic: the pre-cleanup ASR text, shown only when
                    // it differs from the displayed text. Words present here
                    // but missing above = the LFM2.5 cleanup dropped them.
                    if showOriginalRecognition, raws != paragraph.map(\.sourceText) {
                        Text(TranscriptParagraphs.joined(raws))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                    if !translations.isEmpty {
                        Text(TranscriptParagraphs.joined(translations))
                    }
                }
                .id(paragraph.first?.id)
                .background(
                    paragraph.contains { $0.id == currentPlayingEntryID }
                        ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture {
                    if let first = paragraph.first { seekPlayback(to: first) }
                }
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

    /// Entry the playhead is currently inside, for the subtle follow-along
    /// highlight while audio plays.
    private var currentPlayingEntryID: UUID? {
        guard playback.isPlaying, let session else { return nil }
        return session.entries.last {
            session.resolvedAudioOffset(of: $0) <= playback.currentTime
        }?.id
    }

    /// Tap a transcript line → jump the recording there. Explains itself
    /// instead of silently ignoring the tap while a live session holds the
    /// audio hardware.
    private func seekPlayback(to entry: SessionRecord.Entry) {
        guard let session, let fileName = session.audioFileName else { return }
        guard !pipeline.isRunning else {
            showNotice(String(localized: "Tap-to-play is available after the recording stops."))
            return
        }
        playback.load(url: SessionArchive.recordingURL(fileName: fileName))
        playback.seek(to: session.resolvedAudioOffset(of: entry))
        if !playback.isPlaying { playback.togglePlay() }
    }

    private func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }

    /// True (and shows the reason) when a live recording blocks post-hoc
    /// work: these actions share the LLM + GPU with live capture and the
    /// job center silently rejects them mid-recording, so the tap must
    /// explain itself instead of no-op'ing. Actions call this first.
    private func blockedByRecording() -> Bool {
        guard pipeline.isRunning else { return false }
        showNotice(String(localized: "Wait until the current recording finishes."))
        return true
    }

    /// Every photo for the session, oldest first — all shown together in the
    /// Photos section (anchoring is kept only to ground descriptions).
    private func allAttachments(
        _ session: SessionRecord
    ) -> [SessionRecord.Attachment] {
        (session.attachments ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    private func saveCaption(_ caption: String, for attachment: SessionRecord.Attachment) {
        guard var updated = session,
              let index = updated.attachments?.firstIndex(where: { $0.id == attachment.id })
        else { return }
        let text = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.attachments?[index].caption = text.isEmpty ? nil : text
        pipeline.archive.update(updated)
    }

    private func deleteAttachment(_ attachment: SessionRecord.Attachment) {
        guard var updated = session else { return }
        updated.attachments?.removeAll { $0.id == attachment.id }
        if updated.attachments?.isEmpty == true { updated.attachments = nil }
        pipeline.archive.update(updated)
        try? FileManager.default.removeItem(
            at: SessionArchive.attachmentURL(fileName: attachment.fileName))
    }

    private func subtitleDocument(
        for session: SessionRecord, format: SubtitleDocument.Format, bilingual: Bool
    ) -> SubtitleDocument {
        let cues = SubtitleExporter.cues(for: session, bilingual: bilingual)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return SubtitleDocument(
            text: format == .srt ? SubtitleExporter.srt(cues) : SubtitleExporter.vtt(cues),
            fileName: "Loqi \(formatter.string(from: session.startedAt))",
            format: format)
    }

    private func recordingSize(_ fileName: String) -> String? {
        guard let bytes = SessionArchive.recordingSizeBytes(fileName: fileName)
        else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "1.3 GB" for the active model — download-consent copy.
    private static var modelSizeText: String {
        ByteCountFormatter.string(
            fromByteCount: ModelCatalog.current.downloadBytes, countStyle: .file)
    }

    // MARK: AI actions (gated: toggle first, downloaded weights second)

    /// Single entry point for every summarize trigger. AI off explains
    /// itself; missing weights ask for download consent; otherwise the job
    /// center runs it (and dedupes if one is already running).
    private func requestSummarize(
        style: SummaryStyle, length: SummaryLength, suggestVocabulary: Bool = false
    ) {
        // Backstop for the summarize triggers (a recording can begin after
        // a confirm dialog opened); the job center would reject it silently.
        guard !blockedByRecording() else { return }
        guard pipeline.llmEnabled else {
            showNotice(String(
                localized: "AI features are off — turn them on in Settings to summarize."))
            return
        }
        guard pipeline.llmDownloaded else {
            pendingDownload = .summarize(style, length, suggestVocabulary: suggestVocabulary)
            return
        }
        pipeline.jobs.summarize(
            sessionID: sessionID, style: style, length: length,
            suggestVocabulary: suggestVocabulary)
    }

    private func requestAutoSummarize(
        style: SummaryStyle, length: SummaryLength, suggestVocabulary: Bool
    ) {
        guard autoPostProcessNewRecordings else {
            requestSummarize(
                style: style, length: length, suggestVocabulary: suggestVocabulary)
            return
        }
        guard pipeline.llmEnabled else {
            showNotice(String(
                localized: "AI features are off — turn them on in Settings to summarize."))
            return
        }
        guard pipeline.llmDownloaded else {
            pendingDownload = .postProcessNewRecording(
                style, length, suggestVocabulary: suggestVocabulary)
            return
        }
        pipeline.jobs.postProcessAndSummarizeNewSession(
            sessionID: sessionID, style: style, length: length,
            suggestVocabulary: suggestVocabulary)
    }

    private func requestRetranscribe(
        sensitivity: MicSensitivity, backend: OfflineTranscriber.Backend?
    ) {
        guard !pipeline.isRunning else { return }
        // ASR + fixup need no LLM; only the re-summary does. With AI on but
        // the model absent, prompt to download it (for the summary). With
        // AI off, re-transcribe runs ASR-only and skips the summary.
        if pipeline.llmEnabled, !pipeline.llmDownloaded {
            pendingDownload = .retranscribe(sensitivity, backend: backend)
            return
        }
        pipeline.jobs.retranscribeAndSummarize(
            sessionID: sessionID, style: selectedStyle, length: selectedLength,
            sensitivity: sensitivity, backend: backend)
    }

    private func requestSuggestHotwords() {
        // Critical: this loads the summary model straight onto pipeline.llm
        // (no heavyGate), which mid-recording swaps the live-refine model
        // out from under live capture and fights it for the GPU. Guard it.
        guard !blockedByRecording() else { return }
        guard pipeline.llmEnabled else {
            showNotice(String(
                localized: "AI features are off — turn them on in Settings for suggestions."))
            return
        }
        guard pipeline.llmDownloaded else {
            pendingDownload = .suggestHotwords
            return
        }
        suggestHotwords(allowDownload: false)
    }

    private func runAfterDownloadConsent(_ action: DownloadAction) {
        switch action {
        case .summarize(let style, let length, let suggestVocabulary):
            pipeline.jobs.summarize(
                sessionID: sessionID, style: style, length: length,
                allowDownload: true, suggestVocabulary: suggestVocabulary)
        case .postProcessNewRecording(let style, let length, let suggestVocabulary):
            pipeline.jobs.postProcessAndSummarizeNewSession(
                sessionID: sessionID, style: style, length: length,
                allowDownload: true, suggestVocabulary: suggestVocabulary)
        case .retranscribe(let sensitivity, let backend):
            pipeline.jobs.retranscribeAndSummarize(
                sessionID: sessionID, style: selectedStyle, length: selectedLength,
                sensitivity: sensitivity, backend: backend, allowDownload: true)
        case .suggestHotwords:
            suggestHotwords(allowDownload: true)
        }
    }

    /// Persists a style/length choice (session + app default) and
    /// regenerates when a summary exists. The edited-summary confirm
    /// happens upstream in `regenerateSummary` before this is called.
    private func applySummaryPreferences(style: SummaryStyle, length: SummaryLength) {
        defaultStyleRaw = style.rawValue
        defaultLengthRaw = length.rawValue
        guard var updated = session else { return }
        updated.summaryStyle = style.rawValue
        updated.summaryLength = length.rawValue
        pipeline.archive.update(updated)
        // Re-styling an existing summary is reduce-only over the cached
        // notes — cheap enough to just do, no extra "apply" step. Length
        // changes reuse the same notes and only alter reduce caps/tokens.
        if updated.summary != nil { requestSummarize(style: style, length: length) }
    }

    /// Persist a new style/length and regenerate — guarding a hand-edited
    /// summary behind the same "replace?" confirm the wand's Re-summarize
    /// uses. (`applySummaryPreferences` only regenerates when a summary
    /// already exists; picking a style before the first summary just sets
    /// the preference, matching the old sheet.)
    private func regenerateSummary(style: SummaryStyle, length: SummaryLength) {
        if blockedByRecording() { return }
        if session?.summaryEdited == true {
            pendingRegenerate = PendingRegenerate(style: style, length: length)
            confirmRegenerate = true
        } else {
            applySummaryPreferences(style: style, length: length)
        }
    }

    private struct PendingRegenerate {
        let style: SummaryStyle
        let length: SummaryLength
    }

    private func startRename(_ slot: Int) {
        guard slot >= 0 else { return }
        renameText = session?.speakerNames[slot] ?? ""
        renamingSlot = slot
    }

    private func saveSummaryEdit() {
        defer { isEditingSummary = false }
        guard var updated = session else { return }
        let text = summaryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty or unchanged edits revert rather than clearing the summary.
        guard !text.isEmpty, text != updated.summary else { return }
        let old = updated.summary ?? ""
        updated.summary = text
        updated.summaryEdited = true
        pipeline.archive.update(updated)
        mineVocabulary(old: old, new: text)
    }

    /// Best-effort vocabulary mining from what the user typed while
    /// correcting the summary: diff → LLM filter → pending suggestions in
    /// the Vocabulary tab. Never blocks saving; if the LLM is disabled,
    /// not downloaded, or fails, the raw inserted spans queue instead.
    private func mineVocabulary(old: String, new: String) {
        let spans = SummaryDiff.insertedSpans(old: old, new: new)
        guard !spans.isEmpty else { return }
        let store = pipeline.hotwords
        let llm = pipeline.llm
        let llmAllowed = pipeline.llmEnabled
        let sourceID = session?.id
        let sourceTitle = session?.title
        Task {
            let fallback = spans.filter { $0.count <= 40 }.prefix(5)
                .map { (term: $0, note: "") }
            guard llmAllowed else {
                return store.enqueueSuggestions(
                    Array(fallback), sessionID: sourceID, sessionTitle: sourceTitle)
            }
            do {
                await llm.setModel(ModelCatalog.summaryModel)
                try await llm.load(policy: .requireDownloaded)
                let builder = PromptBuilder()
                let prompt = builder.summaryEditMiningPrompt(insertedSpans: spans)
                let raw = try await llm.generate(
                    system: prompt.system, user: prompt.user, maxTokens: 200)
                // An LLM that answers but finds nothing queues nothing;
                // the fallback is for failure only.
                store.enqueueSuggestions(
                    builder.parseHotwordSuggestions(raw, limit: 5),
                    sessionID: sourceID, sessionTitle: sourceTitle)
            } catch {
                store.enqueueSuggestions(
                    Array(fallback), sessionID: sourceID, sessionTitle: sourceTitle)
            }
        }
    }

    private func suggestHotwords(allowDownload: Bool) {
        guard let session else { return }
        suggesting = true
        actionError = nil
        Task {
            defer { suggesting = false }
            do {
                await pipeline.llm.setModel(ModelCatalog.summaryModel)
                try await pipeline.llm.load(
                    policy: allowDownload ? .downloadIfNeeded : .requireDownloaded)
                let builder = PromptBuilder()
                let transcript = session.plainTranscript(includeSpeakers: false)
                let budget = PromptBuilder.suggestionBudget(
                    transcriptLength: transcript.count)
                let direction = session.entries.last?.direction
                let prompt = builder.hotwordSuggestionPrompt(
                    transcript: transcript,
                    sourceLanguage: direction?.source,
                    targetLanguage: direction?.target,
                    limit: budget)
                let raw = try await pipeline.llm.generate(
                    system: prompt.system, user: prompt.user, maxTokens: 200)
                suggestions = builder.parseHotwordSuggestions(
                    raw, limit: budget, targetLanguage: direction?.target)
                    .filter { !pipeline.hotwords.isKnown($0.term) }
                if suggestions.isEmpty {
                    actionError = String(localized: "No new terms found.")
                }
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func suggestionDetail(_ suggestion: HotwordSuggestion) -> String {
        let renderings = AppLanguage.allCases
            .compactMap { suggestion.renderings[$0] }
            .filter { !$0.isEmpty && $0 != suggestion.term }
        return (renderings + [suggestion.note].filter { !$0.isEmpty })
            .joined(separator: " · ")
    }
}

/// Renders the summary markdown (overview paragraph, "## " section headings,
/// bullet lines) with real typography: paragraphs read as prose, headings
/// separate sections, bullets get a hanging indent and breathing room.
/// Legacy plain-text summaries (no headings) render as before.
struct SummaryTextView: View {
    let summary: String

    enum Part: Equatable {
        case heading(String)
        case paragraph(String)
        case bullet(String)
    }

    /// Small models vary the bullet glyph; accept the common ones. Any line
    /// of leading "#"s is a heading regardless of its text — rendering never
    /// keys on heading words, so hand-edits can't break it.
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
            } else if line.hasPrefix("#") {
                closeParagraph()
                let text = line.drop(while: { $0 == "#" })
                    .trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { parts.append(.heading(text)) }
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
                case .heading(let text):
                    Text(text)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
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

/// Per-record language controls in a labeled form. Selection is STAGED:
/// browsing the pickers changes nothing — the record persists and the
/// re-translate job runs only when the user taps Apply. Closing the
/// sheet without applying discards the staged choices.
struct SessionLanguagesSheet: View {
    let pipeline: CaptionPipeline
    let sessionID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var stagedSpoken: String
    @State private var stagedTranslate: String
    @State private var stagedSummary: String

    init(pipeline: CaptionPipeline, sessionID: UUID) {
        self.pipeline = pipeline
        self.sessionID = sessionID
        let record = pipeline.archive.sessions.first { $0.id == sessionID }
        _stagedSpoken = State(initialValue: record?.spokenLanguageRaw ?? "")
        _stagedTranslate = State(initialValue: Self.currentTranslateRaw(record))
        _stagedSummary = State(initialValue: record?.summaryLanguageRaw ?? "")
    }

    private var session: SessionRecord? {
        pipeline.archive.sessions.first { $0.id == sessionID }
    }

    private var locked: Bool {
        pipeline.jobs.isBusy(sessionID) || pipeline.isRunning
    }

    private var spokenChanged: Bool {
        // Compare against the EXPLICIT override ("" = Auto/no override),
        // NOT an inherited display value: for an Auto session the picker
        // shows "Auto", so picking the first entry's own language still
        // registers as a change and becomes an explicit override — the
        // fix for forcing a whole misdetected session to one language.
        stagedSpoken != (session?.spokenLanguageRaw ?? "")
    }
    private var translateChanged: Bool {
        stagedTranslate != Self.currentTranslateRaw(session)
    }
    private var summaryChanged: Bool {
        stagedSummary != (session?.summaryLanguageRaw ?? "")
    }
    private var hasChanges: Bool {
        spokenChanged || translateChanged || summaryChanged
    }

    var body: some View {
        SelectorSheet(
            title: "Languages",
            locked: locked,
            lockedNote: pipeline.isRunning
                ? "Language changes pause until the current recording finishes."
                : "Language changes pause while this session is processing.",
            primaryActionTitle: "Apply",
            primaryActionDisabled: !hasChanges || locked,
            primaryAction: { applyStaged() }
        ) {
            Section {
                Picker("Spoken language", selection: $stagedSpoken) {
                    Text("Auto").tag("")
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
            } footer: {
                Text("What the recording is in. Auto detects each line on its own; picking a language forces the whole recording to it — fixing a wrong or misdetected language. Re-transcription, translation, and transcript cleanup all follow it.")
            }
            Section {
                Picker("Translate to", selection: $stagedTranslate) {
                    Text("Off").tag("")
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shows a translation under each transcript line.")
                    if spokenChanged || translateChanged {
                        Text("Applying re-translates the transcript with the new languages.")
                    }
                }
            }
            Section {
                Picker("Summary language", selection: $stagedSummary) {
                    Text("Auto").tag("")
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
            } footer: {
                Text("The language summaries are written in. Auto follows your device language. Applies the next time you summarize.")
            }
        }
    }

    /// The target the record was made with; transcribe-only shows as Off.
    private static func currentTranslateRaw(_ record: SessionRecord?) -> String {
        if let explicit = record?.translateToRaw { return explicit }
        guard let base = record?.entries.first?.direction,
              base.source != base.target else { return "" }
        return base.target.rawValue
    }

    private func applyStaged() {
        guard var updated = session else { return }
        let translationAffected = spokenChanged || translateChanged
        // "" (Auto) clears the override back to per-line detection.
        if spokenChanged {
            updated.spokenLanguageRaw = stagedSpoken.isEmpty ? nil : stagedSpoken
        }
        if translateChanged { updated.translateToRaw = stagedTranslate }
        if summaryChanged {
            updated.summaryLanguageRaw = stagedSummary.isEmpty ? nil : stagedSummary
        }
        pipeline.archive.update(updated)
        if translationAffected {
            pipeline.jobs.retranslate(sessionID: sessionID)
        }
        // The retranslate progress shows on the detail view — hand back.
        dismiss()
    }
}

/// Pre-flight for Re-transcribe & summarize — every option is tunable here
/// so the user never has to leave for Settings or the Languages sheet:
/// the engine (when more than one is installed for the session's
/// languages), speaker handling (when the session is unlabeled),
/// translation target, and mic pickup, with the edited-summary warning
/// inline. Choices that are session state (translation, speakers) persist
/// on Start; the engine override rides the job directly.
struct RetranscribeOptionsSheet: View {
    @Bindable var pipeline: CaptionPipeline
    let sessionID: UUID
    /// Host's requestRetranscribe (handles the AI gates + download consent).
    let start: (MicSensitivity, OfflineTranscriber.Backend?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var sensitivityRaw: String
    /// "" until seeded to the auto-picked engine; then a Backend rawValue.
    @State private var backendRaw: String
    /// "" = translation off, else an AppLanguage rawValue.
    @State private var translateToRaw: String
    /// -1 = Auto; only meaningful when `canChooseSpeakers`.
    @State private var speakerCount: Int

    init(
        pipeline: CaptionPipeline, sessionID: UUID,
        start: @escaping (MicSensitivity, OfflineTranscriber.Backend?) -> Void
    ) {
        self.pipeline = pipeline
        self.sessionID = sessionID
        self.start = start
        let record = pipeline.archive.sessions.first { $0.id == sessionID }
        // Recordings don't store their preset; the current live preset is
        // the best default (it's what capture just used).
        _sensitivityRaw = State(initialValue: MicSensitivity.current.rawValue)
        _backendRaw = State(initialValue: Self.autoBackend(record)?.rawValue ?? "")
        _translateToRaw = State(initialValue: Self.currentTranslateRaw(record))
        _speakerCount = State(initialValue: record?.recordingSpeakerCount ?? -1)
    }

    private var sensitivity: MicSensitivity {
        MicSensitivity(rawValue: sensitivityRaw) ?? .current
    }

    private var session: SessionRecord? {
        pipeline.archive.sessions.first { $0.id == sessionID }
    }

    /// Installed engines that fit the session's languages, best-first —
    /// the same priority `currentBackend` auto-picks from.
    private var availableBackends: [OfflineTranscriber.Backend] {
        let langs = session?.accuracyPassLanguages ?? []
        var list: [OfflineTranscriber.Backend] = []
        if DolphinModelStore.isInstalled, OfflineTranscriber.dolphinSupports(langs) {
            list.append(.dolphin)
        }
        if SenseVoiceModelStore.isInstalled { list.append(.senseVoice) }
        list.append(.apple)
        return list
    }

    private static func autoBackend(_ record: SessionRecord?) -> OfflineTranscriber.Backend? {
        OfflineTranscriber.currentBackend(
            sourceLanguages: record?.accuracyPassLanguages ?? [])
    }

    private var chosenBackend: OfflineTranscriber.Backend {
        availableBackends.first { $0.rawValue == backendRaw }
            ?? availableBackends.first ?? .apple
    }

    /// Speaker count only affects an unlabeled session — a labeled one
    /// inherits its slots by overlap to protect renames (use "Identify
    /// speakers" to deliberately re-cluster).
    private var canChooseSpeakers: Bool {
        session?.entries.contains { $0.speaker != nil } == false
            && VoiceprintService.isOfflineDiarizerDownloaded
    }

    var body: some View {
        SelectorSheet(
            title: "Re-transcribe & summarize",
            // A recording that STARTS while this is open locks it: the job
            // would be silently rejected otherwise (the menu button that
            // opened it can't, since the recording began after).
            locked: pipeline.isRunning,
            lockedNote: "Re-transcribing pauses until the current recording finishes.",
            primaryActionTitle: "Start",
            primaryActionDisabled: pipeline.isRunning,
            primaryAction: {
                persistChoices()
                dismiss()
                // Force the picked engine only when there was a choice.
                start(sensitivity, availableBackends.count > 1 ? chosenBackend : nil)
            }
        ) {
            if let session {
                Section {
                    if availableBackends.count > 1 {
                        Picker("Engine", selection: $backendRaw) {
                            ForEach(availableBackends, id: \.rawValue) { backend in
                                Text(backend.displayName).tag(backend.rawValue)
                            }
                        }
                    } else {
                        LabeledContent("Engine", value: chosenBackend.displayName)
                    }
                    if canChooseSpeakers {
                        Picker("Speakers", selection: $speakerCount) {
                            Text("Auto").tag(-1)
                            ForEach(2...6, id: \.self) { Text("\($0) speakers").tag($0) }
                        }
                    } else {
                        LabeledContent("Speakers", value: speakersText(session))
                    }
                    Picker("Translate to", selection: $translateToRaw) {
                        Text("Off").tag("")
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.displayName).tag(language.rawValue)
                        }
                    }
                    Picker("Mic pickup", selection: $sensitivityRaw) {
                        ForEach(MicSensitivity.allCases) { preset in
                            Label(preset.displayName, systemImage: preset.symbolName)
                                .tag(preset.rawValue)
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if pipeline.llmEnabled {
                            Text("Replaces the transcript with a fresh transcription of the recording, then summarizes again.")
                        } else {
                            Text("Replaces the transcript with a fresh transcription of the recording. AI features are off, so it skips cleanup and doesn't re-summarize.")
                        }
                        Text("Mic pickup should match how the recording was made — pick a wider setting if distant speakers were missed. Runs much faster than the recording length. Everything stays on this iPhone.")
                    }
                }
                if session.summaryEdited == true {
                    Section {
                        Label(
                            "You edited this summary. Summarizing again will replace your changes.",
                            systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    /// Persist the choices that are session state, so the job reads them
    /// when it runs. The engine override isn't stored — it rides `start`.
    private func persistChoices() {
        guard var updated = session else { return }
        var changed = false
        if translateToRaw != Self.currentTranslateRaw(session) {
            updated.translateToRaw = translateToRaw
            changed = true
        }
        if canChooseSpeakers, (updated.recordingSpeakerCount ?? -1) != speakerCount {
            updated.recordingSpeakerCount = speakerCount
            changed = true
        }
        if changed { pipeline.archive.update(updated) }
    }

    /// The target the record currently translates into; "" = off. Mirrors
    /// SessionLanguagesSheet so the two stay consistent.
    private static func currentTranslateRaw(_ record: SessionRecord?) -> String {
        if let explicit = record?.translateToRaw { return explicit }
        guard let base = record?.entries.first?.direction,
              base.source != base.target else { return "" }
        return base.target.rawValue
    }

    private func speakersText(_ session: SessionRecord) -> String {
        if session.entries.contains(where: { $0.speaker != nil }) {
            return String(localized: "Keeps current labels")
        }
        return String(localized: "Not separated")
    }
}

/// Pre-flight for Identify speakers: pick how many voices to look for
/// before the pass runs. Auto discovers the count but can over-split on
/// hard audio; an exact count is the reliable path when the user knows
/// how many people were in the room.
struct IdentifySpeakersSheet: View {
    let pipeline: CaptionPipeline
    let sessionID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var speakerCount: Int

    init(pipeline: CaptionPipeline, sessionID: UUID) {
        self.pipeline = pipeline
        self.sessionID = sessionID
        let stored = pipeline.archive.sessions
            .first { $0.id == sessionID }?.recordingSpeakerCount
        _speakerCount = State(initialValue: stored.flatMap {
            VoiceprintService.separationEnabled(forPickerValue: $0) ? $0 : nil
        } ?? -1)
    }

    var body: some View {
        SelectorSheet(
            title: "Identify speakers",
            locked: pipeline.isRunning,
            lockedNote: "Speaker identification pauses until the current recording finishes.",
            primaryActionTitle: "Start",
            primaryActionDisabled: pipeline.isRunning,
            primaryAction: {
                pipeline.jobs.retryDiarization(
                    sessionID: sessionID, speakerCount: speakerCount)
                dismiss()
            }
        ) {
            Section {
                Picker("Speakers", selection: $speakerCount) {
                    Text("Auto").tag(-1)
                    ForEach(2...6, id: \.self) { Text("\($0) speakers").tag($0) }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Auto discovers the count from the audio. If it finds too many, set the exact number of people.")
                    Text("Re-identifying reassigns speaker slots, so custom speaker names may move.")
                }
            }
        }
    }
}
