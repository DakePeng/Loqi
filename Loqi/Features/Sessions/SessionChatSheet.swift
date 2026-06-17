import SwiftUI

/// On-device Q&A over one saved session. ChatEngine grounds answers in the
/// session's chunk notes and transcript; the exchange persists on the
/// record (capped) so reopening the sheet keeps the thread.
struct SessionChatSheet: View {
    @Bindable var pipeline: CaptionPipeline
    let sessionID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [SessionRecord.ChatMessage] = []
    @State private var input = ""
    @State private var answering = false
    @State private var modelLoading = false
    @State private var answerTask: Task<Void, Never>?
    @State private var actionError: String?
    /// Cached once per appearance: the downloaded check stats the disk and
    /// must not run on every keystroke's body evaluation.
    @State private var modelDownloaded = true
    /// Consented in-sheet weights download; nil when none is running.
    @State private var downloadProgress: Double?

    private var session: SessionRecord? {
        pipeline.archive.sessions.first { $0.id == sessionID }
    }

    private var starters: [String] {
        [
            String(localized: "What were the action items?"),
            String(localized: "What was decided?"),
            String(localized: "Summarize the key points"),
        ]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if messages.isEmpty, !answering {
                                emptyState
                            }
                            ForEach(messages) { message in
                                bubble(message)
                            }
                            if answering {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text(modelLoading
                                        ? "Preparing the model…" : "Thinking…")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let actionError {
                                Text(actionError)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id("bottom")
                        }
                        .padding(.horizontal)
                        .padding(.top, 12)
                    }
                    .onChange(of: messages.count) {
                        withAnimation { proxy.scrollTo("bottom") }
                    }
                    .onChange(of: answering) {
                        withAnimation { proxy.scrollTo("bottom") }
                    }
                }
                inputBar
            }
            .navigationTitle("Ask this session")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
#if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear chat", systemImage: "trash", role: .destructive) {
                        clearChat()
                    }
                    .disabled(messages.isEmpty || answering)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
#else
                ToolbarItem(placement: .destructiveAction) {
                    Button("Clear chat", systemImage: "trash", role: .destructive) {
                        clearChat()
                    }
                    .disabled(messages.isEmpty || answering)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
#endif
            }
        }
        .onAppear {
            messages = session?.chatHistory ?? []
            modelDownloaded = pipeline.llmDownloaded
        }
        .onDisappear { answerTask?.cancel() }
    }

    /// Why sending is blocked right now, or nil when chat is ready.
    private var sendBlockedReason: LocalizedStringKey? {
        if pipeline.isRunning { return "Available after the recording ends." }
        if !pipeline.llmEnabled {
            return "AI features are off — turn them on in Settings to chat."
        }
        return nil
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Answers come from this session's notes and transcript, entirely on-device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(starters, id: \.self) { starter in
                Button {
                    send(starter)
                } label: {
                    Text(starter)
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
        }
        .padding(.bottom, 8)
    }

    private func bubble(_ message: SessionRecord.ChatMessage) -> some View {
        HStack {
            if message.isUser { Spacer(minLength: 48) }
            Text(message.text)
                .font(.callout)
                .textSelection(.enabled)
                .foregroundStyle(message.isUser ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    message.isUser
                        ? AnyShapeStyle(.tint)
                        : AnyShapeStyle(Color.loqiSecondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if !message.isUser { Spacer(minLength: 48) }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            if let reason = sendBlockedReason {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if !modelDownloaded {
                // Chat is the feature; the model is the dependency. Make the
                // missing download an explicit, consented step — never a
                // surprise gigabyte pull behind "Thinking…".
                if let downloadProgress {
                    ProgressView(value: downloadProgress) {
                        Text("Downloading AI model… \(downloadProgress.formatted(.percent.precision(.fractionLength(0))))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 8) {
                        Text("Chat runs on the AI model (\(Self.modelSizeText), one-time download).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Download") { startModelDownload() }
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                }
            }
            HStack(spacing: 10) {
                TextField("Ask about this session", text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Color.loqiSecondarySystemBackground,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .onSubmit { send(input) }
                    .disabled(sendBlockedReason != nil)
                if answering {
                    Button {
                        answerTask?.cancel()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Stop")
                } else {
                    Button {
                        send(input)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Send")
                    .disabled(
                        input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || sendBlockedReason != nil || !modelDownloaded)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private static var modelSizeText: String {
        ByteCountFormatter.string(
            fromByteCount: ModelCatalog.current.downloadBytes, countStyle: .file)
    }

    private func startModelDownload() {
        downloadProgress = 0
        actionError = nil
        Task {
            do {
                try await pipeline.llm.load { fraction in
                    Task { @MainActor in downloadProgress = fraction }
                }
                modelDownloaded = true
            } catch {
                actionError = error.localizedDescription
            }
            downloadProgress = nil
        }
    }

    private func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !answering, session != nil,
              sendBlockedReason == nil, modelDownloaded else { return }
        input = ""
        actionError = nil
        messages.append(.init(role: "user", text: question, date: .now))
        persist()
        answering = true
        answerTask = Task {
            defer {
                answering = false
                modelLoading = false
                answerTask = nil
            }
            do {
                if case .ready = await pipeline.llm.loadState {} else {
                    modelLoading = true
                }
                guard let record = session else { return }
                let engine = ChatEngine(llm: pipeline.llm)
                let answer = try await engine.answer(
                    question: question, record: record, history: messages)
                modelLoading = false
                messages.append(.init(role: "assistant", text: answer, date: .now))
                persist()
            } catch is CancellationError {
                // Stopped by the user; the question stays for a retry.
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    /// Freshest-copy write: re-fetch the record and set only chatHistory,
    /// so a concurrent re-summarize is never clobbered.
    private func persist() {
        guard var updated = session else { return }
        updated.chatHistory = messages.isEmpty
            ? nil : Array(messages.suffix(SessionRecord.chatHistoryCap))
        pipeline.archive.update(updated)
    }

    private func clearChat() {
        messages = []
        actionError = nil
        persist()
    }
}
