import SwiftUI

/// One transcript row. The latest entry is the one being read right now, so
/// its translation renders large; older rows recede into a compact history.
struct CaptionRow: View {
    let entry: CaptionEntry
    var isLatest = false

    var body: some View {
        VStack(alignment: .leading, spacing: isLatest ? 6 : 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(entry.sourceText)
                    .font(isLatest ? .subheadline : .caption)
                    .foregroundStyle(entry.state == .volatile ? .tertiary : .secondary)
                    .italic(entry.state == .volatile)
                if entry.rawSourceText != nil {
                    Image(systemName: "pencil.line")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .contextMenu {
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

            if let translation = entry.displayTranslation {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(translation)
                        .font(isLatest
                            ? .title2.weight(.semibold)
                            : .body.weight(.medium))
                        .foregroundStyle(isLatest ? .primary : .secondary)
                        .contentTransition(.opacity)

                    if entry.state == .refining {
                        Image(systemName: "sparkles")
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .symbolEffect(.pulse, isActive: true)
                    }
                }
            } else if entry.draftFailed {
                Label("Translation unavailable", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if entry.state != .volatile {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, isLatest ? 10 : 5)
        .animation(.easeInOut(duration: 0.25), value: entry.displayTranslation)
        .animation(.easeInOut(duration: 0.2), value: isLatest)
    }
}
