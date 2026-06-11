import SwiftUI

/// One transcript row. The latest entry is the one being read right now, so
/// it renders large; older rows recede into a compact history.
///
/// Transcribe-only sessions (no translation) promote the source text to the
/// primary slot — it IS the content, not a caption above a translation.
struct CaptionRow: View {
    let entry: CaptionEntry
    var isLatest = false

    private var transcribeOnly: Bool {
        entry.direction.source == entry.direction.target
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isLatest ? 6 : 3) {
            if transcribeOnly {
                primaryLine(
                    entry.sourceText,
                    italic: entry.state == .volatile,
                    showsPolishMark: entry.rawSourceText != nil,
                    showsSpinner: entry.state == .refining)
                .contextMenu { copyMenu }
            } else {
                sourceLine
                translationBlock
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, isLatest ? 10 : 5)
        .animation(.easeInOut(duration: 0.25), value: entry.displayTranslation)
        .animation(.easeInOut(duration: 0.2), value: isLatest)
    }

    /// Big readable text for whatever the user is actually reading.
    private func primaryLine(
        _ text: String, italic: Bool, showsPolishMark: Bool, showsSpinner: Bool
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(text)
                .font(isLatest
                    ? .title.weight(.semibold)
                    : .title3.weight(.medium))
                .foregroundStyle(italic
                    ? AnyShapeStyle(.tertiary)
                    : isLatest ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .italic(italic)
                .contentTransition(.opacity)

            if showsSpinner {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, isActive: true)
            } else if showsPolishMark {
                Image(systemName: "pencil.line")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var sourceLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(entry.sourceText)
                .font(isLatest ? .body : .footnote)
                .foregroundStyle(entry.state == .volatile ? .tertiary : .secondary)
                .italic(entry.state == .volatile)
            if entry.rawSourceText != nil {
                Image(systemName: "pencil.line")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contextMenu { copyMenu }
    }

    @ViewBuilder
    private var translationBlock: some View {
        if let translation = entry.displayTranslation {
            primaryLine(
                translation,
                italic: false,
                showsPolishMark: false,
                showsSpinner: entry.state == .refining)
        } else if entry.draftFailed {
            Label("Translation unavailable", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if entry.state != .volatile {
            ProgressView()
                .controlSize(.mini)
        }
    }

    @ViewBuilder
    private var copyMenu: some View {
        if let raw = entry.rawSourceText {
            Button {
                UIPasteboard.general.string = raw
            } label: {
                Label("Copy original transcript", systemImage: "doc.on.doc")
            }
            Button {
                UIPasteboard.general.string = entry.sourceText
            } label: {
                Label("Copy polished transcript", systemImage: "sparkles")
            }
        }
    }
}
