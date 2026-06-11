import SwiftUI

/// One-way live captions: listen in one language, read another.
/// The newest translation renders large; auto-scroll follows the live edge
/// but yields the moment the user scrolls back to re-read.
struct LiveCaptionsView: View {
    @Bindable var pipeline: CaptionPipeline

    @AppStorage("captions.source") private var source: AppLanguage = .english
    @AppStorage("captions.target") private var target: AppLanguage = .chinese
    @AppStorage("captions.speakerCount") private var speakerCount = 0
    @State private var errorMessage: String?
    @State private var isAtLiveEdge = true
    @State private var renamingSlot: Int?
    @State private var renameText = ""

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

    private var direction: LanguagePair { LanguagePair(source: source, target: target) }

    var body: some View {
        // One filter pass per body evaluation — the helpers all share it.
        let entries = pipeline.store.entries(in: .captions)
        return NavigationStack {
            VStack(spacing: 0) {
                transcript(entries)
                controls
            }
            .navigationTitle("Record")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") { pipeline.store.clear(.captions) }
                        .disabled(entries.isEmpty)
                }
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
                        description: Text("Start a session and live translated captions will appear here."))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isAtLiveEdge)
        }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            PipelineStatusBar(pipeline: pipeline)

            HStack(spacing: 12) {
                Group {
                    languageMenu(selection: $source)
                    Button {
                        swap(&source, &target)
                    } label: {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.footnote.weight(.semibold))
                    }
                    languageMenu(selection: $target)
                }
                .disabled(pipeline.isRunning)

                // Speaker count is adjustable mid-session: the transcript
                // re-clusters and relabels live.
                Picker("Speakers", selection: $speakerCount) {
                    Label("One voice", systemImage: "person").tag(0)
                    ForEach(2...6, id: \.self) { count in
                        Label("\(count) speakers", systemImage: "person.2").tag(count)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 6)
                .background(Color(.secondarySystemBackground), in: Capsule())
                .onChange(of: speakerCount) {
                    pipeline.updateSpeakerCount(speakerCount)
                }
            }

            LiveLevelMicButton(pipeline: pipeline, isLive: pipeline.isRunning) {
                toggleSession()
            }

            if pipeline.isRunning, let startedAt = pipeline.sessionStartedAt {
                HStack(spacing: 10) {
                    Text(startedAt, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    BatteryHint()
                }
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
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

    private func languageMenu(selection: Binding<AppLanguage>) -> some View {
        Picker("Language", selection: selection) {
            ForEach(AppLanguage.allCases) { language in
                Text(language.displayName).tag(language)
            }
        }
        .pickerStyle(.menu)
        .padding(.horizontal, 6)
        .background(Color(.secondarySystemBackground), in: Capsule())
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
