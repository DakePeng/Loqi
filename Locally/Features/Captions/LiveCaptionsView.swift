import SwiftUI

/// One-way live captions: listen in one language, read another.
/// The newest translation renders large; auto-scroll follows the live edge
/// but yields the moment the user scrolls back to re-read.
struct LiveCaptionsView: View {
    @Bindable var pipeline: CaptionPipeline

    @AppStorage("captions.source") private var source: AppLanguage = .english
    /// Translation is opt-in: empty = off (plain transcription, the default).
    @AppStorage("captions.translation") private var translationRaw = ""
    @AppStorage("captions.speakerCount") private var speakerCount = 0
    @State private var errorMessage: String?
    @State private var isAtLiveEdge = true
    @State private var renamingSlot: Int?
    @State private var renameText = ""
    @State private var showingSummarySoFar = false

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
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        } else {
            portrait(entries)
        }
    }

    private func portrait(_ entries: [CaptionEntry]) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript(entries)
                controls
            }
            .navigationTitle("Record")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Rotation lock is common; this forces landscape
                    // caption mode without it.
                    Button("Landscape", systemImage: "iphone.landscape") {
                        Self.rotate(to: .landscapeRight)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if pipeline.liveNotes.count >= 2 {
                        Button("Summary so far", systemImage: "sparkles") {
                            showingSummarySoFar = true
                        }
                    }
                    if !entries.isEmpty {
                        Button("Clear") { pipeline.store.clear(.captions) }
                    }
                }
            }
            .sheet(isPresented: $showingSummarySoFar) {
                SummarySoFarSheet(pipeline: pipeline)
            }
            .alert("Couldn't start", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
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

    private static let speakerColors: [Color] =
        [.blue, .green, .orange, .purple, .pink, .teal]

    private func transcript(_ entries: [CaptionEntry]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    let lastEntryID = entries.last?.id
                    ForEach(segments(from: entries)) { segment in
                        segmentCard(segment, lastEntryID: lastEntryID)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            // Track whether the user is at the live edge; auto-scroll only
            // then, so reading history never fights incoming captions.
            // contentOffset is inset-relative, so the bottom edge must
            // include the insets or this is never true and follow breaks.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let visibleBottom = geometry.contentOffset.y
                    + geometry.containerSize.height
                let bottomEdge = geometry.contentSize.height
                    + geometry.contentInsets.bottom
                // Content shorter than the viewport is always "at the edge".
                return geometry.contentSize.height <= geometry.containerSize.height
                    || visibleBottom >= bottomEdge - 120
            } action: { _, atBottom in
                isAtLiveEdge = atBottom
            }
            .onChange(of: entries.last?.sourceText) {
                guard isAtLiveEdge, let last = entries.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
            .overlay(alignment: .bottom) {
                if !isAtLiveEdge, pipeline.isRunning {
                    Button {
                        if let last = entries.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    } label: {
                        Label("Back to live", systemImage: "arrow.down.to.line")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
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

    /// Minimal bottom bar. Idle: three compact chips (language, speakers,
    /// optional translation) over the mic. Recording: just the mic, the
    /// timer, and the speakers chip (the one setting that's adjustable
    /// mid-session) — everything else gets out of the way.
    private var controls: some View {
        VStack(spacing: 14) {
            PipelineStatusBar(pipeline: pipeline)

            if !pipeline.isRunning {
                HStack(spacing: 10) {
                    languageChip
                    speakersChip
                    translationChip
                }
            }

            LiveLevelMicButton(pipeline: pipeline, isLive: pipeline.isRunning) {
                toggleSession()
            }

            if pipeline.isRunning, let startedAt = pipeline.sessionStartedAt {
                HStack(spacing: 12) {
                    Text(startedAt, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    BatteryHint()
                    speakersChip
                }
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .animation(.easeInOut(duration: 0.2), value: pipeline.isRunning)
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

    /// Speaker count is adjustable mid-session: the transcript re-clusters
    /// and relabels live.
    private var speakersChip: some View {
        Menu {
            Picker("Speakers", selection: $speakerCount) {
                Label("One voice", systemImage: "person").tag(0)
                ForEach(2...6, id: \.self) { count in
                    Label("\(count) speakers", systemImage: "person.2").tag(count)
                }
            }
        } label: {
            chip(
                icon: speakerCount >= 2 ? "person.2" : "person",
                text: speakerCount >= 2 ? "\(speakerCount)" : "1",
                active: speakerCount >= 2)
        }
        .onChange(of: speakerCount) {
            pipeline.updateSpeakerCount(speakerCount)
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
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
            if speakerCount >= 2 {
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
                            pipeline.speakerNames[$0] ?? "Speaker \($0 + 1)"
                        } ?? "…")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    }
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
                    errorMessage = "Microphone access is required. Enable it in Settings."
                    return
                }
                do {
                    try await pipeline.start(direction: direction)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

/// On-demand digest of the session so far, reduced from the live chunk
/// notes — no transcript mapping, so it returns in one generation.
private struct SummarySoFarSheet: View {
    let pipeline: CaptionPipeline

    @Environment(\.dismiss) private var dismiss
    @State private var summary: String?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if let summary {
                    ScrollView {
                        SummaryTextView(summary: summary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                } else if failed {
                    ContentUnavailableView(
                        "Summary failed — try again.",
                        systemImage: "exclamationmark.triangle")
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
            let notes = pipeline.liveNotes
            let language = AppLanguage.devicePreferred
                ?? pipeline.activeDirection?.target ?? .english
            do {
                let engine = SummaryEngine(llm: pipeline.llm)
                summary = try await engine.reduce(notes: notes, in: language)
            } catch {
                failed = true
            }
        }
    }
}
