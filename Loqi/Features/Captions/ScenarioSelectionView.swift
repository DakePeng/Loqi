import SwiftUI

/// The step between stopping a recording and seeing its summary: pick what
/// kind of session it was (the summary style) to summarize now, open the
/// session as-is, or skip back to the mic. A short transcript preview keeps
/// the choice grounded in what was actually said.
struct ScenarioSelectionView: View {
    @Bindable var pipeline: CaptionPipeline
    let sessionID: UUID
    /// Navigate to the detail view with this summary choice auto-running.
    let onProceed: (SummaryStyle, SummaryLength) -> Void
    /// Navigate to the detail view without summarizing.
    let onView: () -> Void

    @AppStorage("record.autoSuggest") private var autoSuggest = true
    @AppStorage("summary.defaultStyle") private var defaultStyleRaw
        = SummaryStyle.meeting.rawValue
    @AppStorage("summary.defaultLength") private var defaultLengthRaw
        = SummaryLength.standard.rawValue
    @State private var suggestedStyle: SummaryStyle?
    @State private var detecting = false
    @State private var confirmDiscard = false

    /// Resolved live so a mid-flow discard elsewhere can't strand the view.
    private var session: SessionRecord? {
        pipeline.archive.sessions.first { $0.id == sessionID }
    }

    var body: some View {
        if let session {
            content(session)
        } else {
            // The session vanished under us (deleted from the Sessions tab):
            // clear the card or the Record tab is a blank page with no exit.
            Color.clear
                .onAppear { pipeline.clearLastFinishedSession() }
        }
    }

    private func content(_ session: SessionRecord) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                header(session)
                preview(session)
                styleGrid
                lengthPicker
                Toggle(isOn: $autoSuggest) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-suggest")
                            .font(.subheadline.weight(.medium))
                        Text("Suggests a scenario here, and vocabulary after summarizing.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 4)
                footer
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog(
            "Delete this session?",
            isPresented: $confirmDiscard,
            titleVisibility: .visible
        ) {
            Button("Delete recording, transcript and notes", role: .destructive) {
                pipeline.archive.delete(id: sessionID)
                pipeline.clearLastFinishedSession()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
        .task(id: sessionID) {
            // Suggestion only — never woken by a model download: detection
            // is skipped entirely until the weights exist.
            guard autoSuggest, pipeline.llmEnabled, pipeline.llmDownloaded else { return }
            detecting = true
            defer { detecting = false }
            suggestedStyle = try? await SummaryEngine(llm: pipeline.llm)
                .detectStyle(for: session)
        }
    }

    /// Crash recovery reuses this page; the header must not pretend the
    /// stop was clean when the process died mid-recording.
    private func header(_ session: SessionRecord) -> some View {
        VStack(spacing: 6) {
            if pipeline.lastFinishedWasInterrupted {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                Text("Recording was interrupted")
                    .font(.title3.weight(.semibold))
                Text("Everything up to the interruption is saved.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.green)
                Text("Session saved")
                    .font(.title3.weight(.semibold))
            }
            Text(caption(session))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("What kind of recording was this?")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
    }

    /// A glimpse of the content so the choice doesn't run on memory alone:
    /// live note headlines when mapping produced them, the transcript's
    /// first and last lines otherwise.
    @ViewBuilder
    private func preview(_ session: SessionRecord) -> some View {
        let lines = previewLines(session)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func previewLines(_ session: SessionRecord) -> [String] {
        if let notes = session.chunkNotes, !notes.isEmpty {
            return notes.prefix(3).map { "• " + $0.headline }
        }
        let texts = session.entries.map(\.sourceText).filter { !$0.isEmpty }
        guard !texts.isEmpty else { return [] }
        var lines = texts.prefix(2).map { "“\($0)”" }
        if texts.count > 3 { lines.append("…") }
        if texts.count > 2, let last = texts.last {
            lines.append("“\(last)”")
        }
        return lines
    }

    private var styleGrid: some View {
        VStack(spacing: 10) {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 10
            ) {
                ForEach(SummaryStyle.allCases) { style in
                    styleCard(style)
                }
            }
            if detecting {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Detecting…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var selectedLength: SummaryLength {
        SummaryLength(rawValue: defaultLengthRaw) ?? .standard
    }

    private var lengthBinding: Binding<SummaryLength> {
        Binding(
            get: { selectedLength },
            set: { defaultLengthRaw = $0.rawValue })
    }

    private var lengthPicker: some View {
        Picker("Summary length", selection: lengthBinding) {
            ForEach(SummaryLength.allCases) { length in
                Label(length.displayName, systemImage: length.symbolName)
                    .tag(length)
            }
        }
        .pickerStyle(.segmented)
    }

    private func styleCard(_ style: SummaryStyle) -> some View {
        Button {
            defaultStyleRaw = style.rawValue
            defaultLengthRaw = selectedLength.rawValue
            onProceed(style, selectedLength)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: style.symbolName)
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text(style.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .padding(.vertical, 12)
            .background(
                Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                if style == suggestedStyle {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.tint, lineWidth: 1.5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if style == suggestedStyle {
                    Text("Suggested")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.tint, in: Capsule())
                        .offset(x: -6, y: -7)
                }
            }
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: suggestedStyle)
    }

    /// "View session" is the neutral path the page used to lack: open what
    /// was recorded without committing to a summary. Discard is deliberately
    /// the quietest control here — it deletes the whole session.
    private var footer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Button {
                    pipeline.clearLastFinishedSession()
                } label: {
                    Text("Skip")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    onView()
                } label: {
                    Label("View only", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            Button(role: .destructive) {
                confirmDiscard = true
            } label: {
                Label("Discard session…", systemImage: "trash")
                    .font(.footnote)
            }
            .buttonStyle(.borderless)
        }
    }

    /// "3:25 · 1.2 MB" — duration, plus audio size while the file exists.
    private func caption(_ session: SessionRecord) -> String {
        var parts = [Duration.seconds(session.duration)
            .formatted(.time(pattern: .minuteSecond))]
        if let fileName = session.audioFileName,
           let bytes = SessionArchive.recordingSizeBytes(fileName: fileName) {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }
}
