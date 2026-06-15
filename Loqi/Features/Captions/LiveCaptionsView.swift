import PhotosUI
import SwiftUI

/// One-way live captions: listen in one language, read another.
/// The newest translation renders large; auto-scroll follows the live edge
/// but yields the moment the user scrolls back to re-read.
struct LiveCaptionsView: View {
    @Bindable var pipeline: CaptionPipeline
    var switchToSessions: () -> Void = {}

    @AppStorage("captions.source") private var source: AppLanguage = .english
    /// Translation is opt-in: empty = off (plain transcription, the default).
    @AppStorage("captions.translation") private var translationRaw = ""
    @AppStorage("captions.speakerCount") private var speakerCount = 0
    @AppStorage(MicSensitivity.defaultsKey) private var sensitivityRaw
        = MicSensitivity.balanced.rawValue
    @State private var errorMessage: String?
    /// Start failed on the mic permission: the alert offers Open Settings
    /// instead of describing the journey.
    @State private var errorIsPermission = false
    @State private var isAtLiveEdge = true
    /// Whether the current scroll motion is user-driven (drag/fling) as
    /// opposed to our own follow animation — only the user may disengage
    /// the live edge.
    @State private var isUserScrolling = false
    @State private var renamingSlot: Int?
    @State private var renameText = ""
    @State private var showingSummarySoFar = false
    @State private var showingCamera = false
    @State private var showingPhotoLibrary = false
    @State private var photoItem: PhotosPickerItem?
    @State private var viewingAttachment: SessionRecord.Attachment?

    /// Push target after the post-stop scenario step: the session detail —
    /// One card per coherent stretch of speech: same speaker, no long
    /// pause between utterances, and bounded length — an approximation of
    /// semantic segments that needs no extra ML.
    private struct Segment: Identifiable {
        let id: UUID            // first entry's id — stable
        let speaker: Int?
        var entries: [CaptionEntry]
    }

    /// A pause this long starts a new card even for the same speaker.
    private static let segmentGap: TimeInterval = 12
    /// Cards stay "little": cap utterances per card.
    private static let segmentMaxEntries = 4

    private var translationTarget: AppLanguage? { AppLanguage(rawValue: translationRaw) }
    private var direction: LanguagePair {
        LanguagePair(source: source, target: translationTarget ?? source)
    }

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // One filter pass per body evaluation — the helpers all share it.
        let entries = pipeline.store.entries(in: .captions)
        // Rotating to landscape turns the screen into a full-bleed caption
        // display; rotating back restores the full Record UI.
        if verticalSizeClass == .compact {
            HorizontalCaptionView(pipeline: pipeline, entries: entries) {
                toggleSession()
            }
            .toolbar(.hidden, for: .tabBar)
            .alert("Couldn't start", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                startErrorButtons
            } message: {
                Text(errorMessage ?? "")
            }
        } else {
            portrait(entries)
        }
    }

    private func portrait(_ entries: [CaptionEntry]) -> some View {
        NavigationStack {
            Group {
                // The post-stop scenario step takes over the page; picking a
                // style pushes the detail view, Skip/Discard return to idle.
                if let finishedID = pipeline.lastFinishedSessionID, !pipeline.isRunning {
                    ScenarioSelectionView(
                        pipeline: pipeline,
                        sessionID: finishedID,
                        onProceed: { style, length in
                            pipeline.jobs.summarize(
                                sessionID: finishedID,
                                style: style,
                                length: length,
                                suggestVocabulary: true)
                            pipeline.clearLastFinishedSession()
                            switchToSessions()
                        },
                        onView: {
                            pipeline.clearLastFinishedSession()
                            switchToSessions()
                        })
                } else if pipeline.isRunning {
                    VStack(spacing: 0) {
                        transcript(entries)
                        controls
                    }
                } else {
                    idleHome
                }
            }
            .animation(.easeInOut(duration: 0.2), value: pipeline.isRunning)
            .tabHeaderTitle("Record")
            .toolbar {
                // No mid-recording "Clear": the transcript on screen IS
                // the session being archived, and the store resets
                // itself at the next session start.
                if pipeline.isRunning, pipeline.liveNotes.count >= 2 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Summary so far", systemImage: "sparkles") {
                            showingSummarySoFar = true
                        }
                    }
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Rotation lock is common; this forces landscape
                    // caption mode without it. Declared last = outermost,
                    // so its spot is stable when sparkles appears.
                    Button("Landscape", systemImage: "iphone.landscape") {
                        Self.rotate(to: .landscapeRight)
                    }
                }
            }
            .sheet(isPresented: $showingSummarySoFar) {
                SummarySoFarSheet(pipeline: pipeline)
            }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraCaptureView { image in
                    pipeline.attachImage(image)
                }
            }
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
                        pipeline.attachImage(image)
                    }
                }
            }
            .fullScreenCover(item: $viewingAttachment) { attachment in
                // Live view is read-only; captions/delete live in the detail.
                AttachmentViewer(attachment: attachment)
            }
            .alert("Couldn't start", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                startErrorButtons
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("Rename speaker", isPresented: .init(
                get: { renamingSlot != nil },
                set: { if !$0 { renamingSlot = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let slot = renamingSlot {
                        pipeline.speakerNames[slot] = renameText.isEmpty ? nil : renameText
                        // Names are vocabulary: onChange re-biases the live
                        // ASR session toward the name immediately. The note
                        // stays English — notes are LLM prompt hints.
                        pipeline.hotwords.captureIfNew(term: renameText, note: "person name")
                    }
                    renamingSlot = nil
                }
                Button("Cancel", role: .cancel) { renamingSlot = nil }
            }
        }
    }

    /// Group entries into cards: same speaker, short gaps, bounded size.
    /// Unattributed entries (the volatile one, or diarization off) attach
    /// to the current card.
    private func segments(from entries: [CaptionEntry]) -> [Segment] {
        var segments: [Segment] = []
        for entry in entries {
            if var last = segments.last,
               entry.speaker == nil || entry.speaker == last.speaker,
               last.entries.count < Self.segmentMaxEntries,
               let previous = last.entries.last,
               entry.createdAt.timeIntervalSince(previous.createdAt) < Self.segmentGap {
                last.entries.append(entry)
                segments[segments.count - 1] = last
            } else {
                segments.append(Segment(
                    id: entry.id, speaker: entry.speaker, entries: [entry]))
            }
        }
        return segments
    }

    /// Transcript rows: segment cards with attached photos interleaved at
    /// the moment they were taken.
    private enum LiveRow: Identifiable {
        case segment(Segment)
        case photo(SessionRecord.Attachment)

        var id: UUID {
            switch self {
            case .segment(let segment): segment.id
            case .photo(let attachment): attachment.id
            }
        }
    }

    private func rows(from entries: [CaptionEntry]) -> [LiveRow] {
        let segments = segments(from: entries)
        let attachments = pipeline.liveAttachments
        guard !attachments.isEmpty else { return segments.map(LiveRow.segment) }
        var rows: [LiveRow] = []
        var remaining = attachments[...]
        for segment in segments {
            let start = segment.entries.first?.createdAt ?? .distantPast
            while let next = remaining.first, next.timestamp < start {
                rows.append(.photo(next))
                remaining.removeFirst()
            }
            rows.append(.segment(segment))
        }
        rows.append(contentsOf: remaining.map(LiveRow.photo))
        return rows
    }

    private static let speakerColors: [Color] =
        [.blue, .green, .orange, .purple, .pink, .teal]

    private func transcript(_ entries: [CaptionEntry]) -> some View {
        let liveRows = rows(from: entries)
        let scrollBottomID = liveRows.last?.id ?? entries.last?.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    let lastEntryID = entries.last?.id
                    ForEach(liveRows) { row in
                        switch row {
                        case .segment(let segment):
                            segmentCard(segment, lastEntryID: lastEntryID)
                        case .photo(let attachment):
                            AttachmentThumbnail(attachment: attachment)
                                .onTapGesture { viewingAttachment = attachment }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            // Live-edge tracking. Disengaging must be a USER decision:
            // a big appended block (zh + large-type translation easily
            // exceeds any pixel slack) instantly puts the new bottom far
            // away, and if that alone flipped the flag, follow would
            // disengage on its own content and strand the "Back to live"
            // pill — the field bug. So: reaching the bottom always
            // re-engages; only a user-driven scroll phase can disengage.
            .onScrollPhaseChange { _, newPhase in
                isUserScrolling = newPhase == .interacting || newPhase == .decelerating
            }
            // contentOffset is inset-relative, so the bottom edge must
            // include the insets or "at bottom" is never true.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let visibleBottom = geometry.contentOffset.y
                    + geometry.containerSize.height
                let bottomEdge = geometry.contentSize.height
                    + geometry.contentInsets.bottom
                // Content shorter than the viewport is always "at the edge".
                return geometry.contentSize.height <= geometry.containerSize.height
                    || visibleBottom >= bottomEdge - 120
            } action: { _, atBottom in
                if atBottom {
                    isAtLiveEdge = true
                } else if isUserScrolling {
                    isAtLiveEdge = false
                }
            }
            // Follow on ANY content-height change — new entries, translations
            // filling in, refinements rewriting earlier lines — not just
            // last-entry text changes; all of them move the bottom edge.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height
            } action: { oldHeight, newHeight in
                guard oldHeight != newHeight, isAtLiveEdge,
                      let target = scrollBottomID else { return }
                proxy.scrollTo(target, anchor: .bottom)
            }
            .overlay(alignment: .bottom) {
                if !isAtLiveEdge, pipeline.isRunning {
                    Button {
                        // Flip to live-edge immediately so the pill hides and
                        // auto-follow re-engages — a programmatic scroll doesn't
                        // reliably re-fire onScrollGeometryChange to settle it.
                        isAtLiveEdge = true
                        if let target = scrollBottomID {
                            withAnimation { proxy.scrollTo(target, anchor: .bottom) }
                            Task {
                                try? await Task.sleep(for: .milliseconds(350))
                                guard isAtLiveEdge else { return }
                                proxy.scrollTo(target, anchor: .bottom)
                            }
                        }
                    } label: {
                        Label("Back to live", systemImage: "arrow.down.to.line")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "Ready to listen",
                        systemImage: "waveform",
                        description: Text("Tap the mic — everything is transcribed privately on this iPhone."))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isAtLiveEdge)
        }
    }

    /// Idle Record page: a big centered mic — the page's one affordance —
    /// with the capture settings chips beneath it.
    private var idleHome: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 24) {
                LiveLevelMicButton(pipeline: pipeline, isLive: false, size: 108) {
                    toggleSession()
                }
                Text("Tap the mic — everything stays on this iPhone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
            VStack(spacing: 12) {
                // Scrollable: CJK labels compress to vertical glyph stacks
                // when this row is squeezed; overflow scrolls instead.
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        languageChip
                        speakersChip
                        pickupChip
                        translationChip
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize, axes: [.horizontal])
                .defaultScrollAnchor(.center, for: .alignment)
                PipelineStatusBar(pipeline: pipeline)
            }
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
    }

    /// Bottom controls while recording: status pills over the slim bar, so
    /// the transcript dominates the screen.
    private var controls: some View {
        VStack(spacing: 12) {
            PipelineStatusBar(pipeline: pipeline)
            recordingBar
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// Slim recording bar: pulsing dot + timer, the (still-adjustable)
    /// speakers chip, and a compact stop button. During an interruption the
    /// live indicators swap for a paused one — a ticking timer over a dead
    /// mic reads as "still recording".
    private var recordingBar: some View {
        HStack(spacing: 12) {
            if pipeline.isPaused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text("Paused")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: "circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                if let startedAt = pipeline.sessionStartedAt {
                    Text(startedAt, style: .timer)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.primary)
                }
            }

            Spacer()
            Menu {
                Button("Take photo", systemImage: "camera") {
                    showingCamera = true
                }
                Button("Photo library", systemImage: "photo.on.rectangle") {
                    showingPhotoLibrary = true
                }
            } label: {
                Image(systemName: "camera")
                    .font(.body)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Add photo")
            pickupBarButton
            speakersChip
            BatteryHint()
            Spacer()

            Button(role: .destructive) {
                toggleSession()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
    }

    private var languageChip: some View {
        Menu {
            Picker("Language", selection: $source) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
        } label: {
            chip(icon: "waveform", text: source.displayName)
        }
        .onChange(of: source) {
            // Translating into the spoken language makes no sense.
            if translationRaw == source.rawValue { translationRaw = "" }
        }
    }

    /// Diarization is on whenever the picker value maps to a cluster cap
    /// (explicit 2+ or Auto) — same rule the service uses, so the UI and the
    /// pipeline can't disagree about the sentinel values.
    private var diarizationOn: Bool {
        VoiceprintService.clusterCap(forPickerValue: speakerCount) != nil
    }

    /// Speaker count is adjustable mid-session: the transcript re-clusters
    /// and relabels live. "Auto" lets clustering discover the count.
    private var speakersChip: some View {
        Menu {
            Picker("Speakers", selection: $speakerCount) {
                Label("One voice", systemImage: "person").tag(0)
                Label("Auto", systemImage: "person.2.wave.2").tag(-1)
                ForEach(2...6, id: \.self) { count in
                    Label("\(count) speakers", systemImage: "person.2").tag(count)
                }
            }
        } label: {
            chip(
                icon: diarizationOn ? "person.2" : "person",
                text: speakerCount == -1
                    ? String(localized: "Auto")
                    : speakerCount >= 2 ? "\(speakerCount)" : "1",
                active: diarizationOn)
        }
        .onChange(of: speakerCount) {
            pipeline.updateSpeakerCount(speakerCount)
        }
    }

    private var sensitivity: MicSensitivity {
        MicSensitivity(rawValue: sensitivityRaw) ?? .balanced
    }

    /// Mic pickup preset, adjustable mid-session too: switching restarts
    /// the live turn so the VADs and the capture boost rebind.
    private var pickupPicker: some View {
        Picker("Mic pickup", selection: $sensitivityRaw) {
            ForEach(MicSensitivity.allCases) { preset in
                Label(preset.displayName, systemImage: preset.symbolName)
                    .tag(preset.rawValue)
            }
        }
    }

    private var pickupChip: some View {
        Menu {
            pickupPicker
        } label: {
            chip(
                icon: sensitivity.symbolName,
                text: sensitivity.shortName,
                active: sensitivity != .balanced)
        }
        .onChange(of: sensitivityRaw) {
            pipeline.updateMicSensitivity()
        }
    }

    /// Same picker, icon-only — fits the slim recording bar.
    private var pickupBarButton: some View {
        Menu {
            pickupPicker
        } label: {
            Image(systemName: sensitivity.symbolName)
                .font(.body)
                .foregroundStyle(sensitivity != .balanced
                    ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .contentTransition(.symbolEffect(.replace))
                .animation(.default, value: sensitivityRaw)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Mic pickup")
        .onChange(of: sensitivityRaw) {
            pipeline.updateMicSensitivity()
        }
    }

    private var translationChip: some View {
        Menu {
            Picker("Translation", selection: $translationRaw) {
                Text("Off").tag("")
                ForEach(AppLanguage.allCases.filter { $0 != source }) { language in
                    Text(language.displayName).tag(language.rawValue)
                }
            }
        } label: {
            chip(
                icon: "globe",
                text: translationTarget?.displayName ?? String(localized: "Translate"),
                active: translationTarget != nil)
        }
    }

    private func chip(icon: String, text: String, active: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption)
            Text(text)
                .font(.footnote.weight(.medium))
                // Never compress: CJK text otherwise wraps to a vertical
                // stack of glyphs ("自动" one character per line).
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        .background(Color(.secondarySystemBackground), in: Capsule())
    }

    /// One card: speaker chip (when separating), then the segment's
    /// utterances. The card holding the newest entry renders prominent.
    private func segmentCard(_ segment: Segment, lastEntryID: UUID?) -> some View {
        let isLive = segment.entries.contains { $0.id == lastEntryID }
        let accent = segment.speaker.map {
            Self.speakerColors[$0 % Self.speakerColors.count]
        }
        return VStack(alignment: .leading, spacing: 2) {
            if diarizationOn {
                Button {
                    if let slot = segment.speaker {
                        renameText = pipeline.speakerNames[slot] ?? ""
                        renamingSlot = slot
                    }
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(accent ?? Color(.systemGray3))
                            .frame(width: 7, height: 7)
                        Text(segment.speaker.map {
                            pipeline.speakerNames[$0]
                                ?? String(localized: "Speaker \($0 + 1)")
                        } ?? "…")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    }
                    // Bigger tap area than the caption2 glyphs without forcing
                    // a full 44pt row (that would gap every transcript card).
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 2)
            }
            ForEach(segment.entries) { entry in
                CaptionRow(entry: entry, isLatest: entry.id == lastEntryID)
                    .id(entry.id)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemBackground)
                .opacity(isLive ? 1 : 0.6),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .leading) {
            if let accent {
                UnevenRoundedRectangle(
                    topLeadingRadius: 16, bottomLeadingRadius: 16,
                    bottomTrailingRadius: 0, topTrailingRadius: 0)
                .fill(accent.opacity(0.85))
                .frame(width: 4)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isLive)
    }

    /// Programmatic rotation works even with the orientation lock on,
    /// which is exactly when the button is needed.
    static func rotate(to orientation: UIInterfaceOrientationMask) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
    }

    private func toggleSession() {
        Task {
            if pipeline.isRunning {
                await pipeline.stop()
            } else {
                guard await AudioCaptureService.requestPermission() else {
                    errorIsPermission = true
                    errorMessage = String(
                        localized: "Microphone access is required. Enable it in Settings.")
                    return
                }
                do {
                    try await pipeline.start(direction: direction)
                } catch {
                    errorIsPermission = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Shared by the portrait and landscape "Couldn't start" alerts.
    @ViewBuilder
    private var startErrorButtons: some View {
        if errorIsPermission {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
        Button("OK", role: .cancel) {}
    }
}

/// On-demand digest of the session so far, reduced from the live chunk
/// notes — no transcript mapping, so it returns in one generation.
private struct SummarySoFarSheet: View {
    let pipeline: CaptionPipeline

    @Environment(\.dismiss) private var dismiss
    @AppStorage("summary.defaultStyle") private var defaultStyleRaw
        = SummaryStyle.meeting.rawValue
    @AppStorage("summary.defaultLength") private var defaultLengthRaw
        = SummaryLength.standard.rawValue
    @State private var summary: String?
    @State private var failureText: String?

    var body: some View {
        NavigationStack {
            Group {
                if let summary {
                    ScrollView {
                        SummaryTextView(summary: summary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                } else if let failureText {
                    ContentUnavailableView(
                        "Couldn't summarize yet",
                        systemImage: "exclamationmark.triangle",
                        description: Text(failureText))
                } else {
                    ProgressView("Summarizing…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Summary so far")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            // Mid-session photos count too: merge their pseudo-notes the
            // same way the final summarize does.
            let notes = AttachmentNotes.merged(
                pipeline.liveNotes, attachments: pipeline.liveAttachments)
            let language = AppLanguage.devicePreferred
                ?? pipeline.activeDirection?.target ?? .english
            let transcriptCharacters = pipeline.store.entries(in: .captions)
                .reduce(0) { $0 + $1.sourceText.count }
            do {
                let engine = SummaryEngine(llm: pipeline.llm)
                // Mid-session peek stays one fast generation — no stitched
                // detail sections while ASR competes for the model.
                summary = try await engine.reduce(
                    notes: notes,
                    style: SummaryStyle(rawValue: defaultStyleRaw) ?? .meeting,
                    length: SummaryLength(rawValue: defaultLengthRaw) ?? .standard,
                    transcriptCharacterCount: transcriptCharacters,
                    in: language,
                    stitchDetails: false)
            } catch LLMServiceError.modelNotLoaded {
                failureText = String(localized:
                    "The AI model isn't loaded yet — it warms up during pauses in speech. Try again in a moment.")
            } catch LLMServiceError.modelNotDownloaded {
                failureText = String(localized:
                    "AI model not downloaded — transcribing only (see Settings).")
            } catch {
                failureText = error.localizedDescription
            }
        }
    }
}
