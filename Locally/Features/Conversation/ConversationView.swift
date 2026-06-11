import SwiftUI

/// Two-way conversation: split screen, top half rotated to face the other
/// person across the table. Tapping a side's mic claims the turn for that
/// side's language.
struct ConversationView: View {
    @Bindable var pipeline: CaptionPipeline

    @AppStorage("conversation.mine") private var myLanguage: AppLanguage = .chinese
    @AppStorage("conversation.theirs") private var theirLanguage: AppLanguage = .english
    @AppStorage("conversation.tts") private var ttsEnabled = false
    @State private var errorMessage: String?

    /// Direction while *I* speak (translated for them) and vice versa.
    private var outgoing: LanguagePair { LanguagePair(source: myLanguage, target: theirLanguage) }
    private var incoming: LanguagePair { LanguagePair(source: theirLanguage, target: myLanguage) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PipelineStatusBar(pipeline: pipeline)
                    .padding(.vertical, 4)

                // Their half, rotated to face them across the table.
                ConversationHalf(
                    pipeline: pipeline,
                    speaksIn: theirLanguage,
                    direction: incoming,
                    onTapMic: { claimTurn(incoming) })
                .rotationEffect(.degrees(180))

                divider

                ConversationHalf(
                    pipeline: pipeline,
                    speaksIn: myLanguage,
                    direction: outgoing,
                    onTapMic: { claimTurn(outgoing) })
            }
            .navigationTitle("Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    languagePickers
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        ttsEnabled.toggle()
                        if !ttsEnabled { pipeline.speech.stop() }
                    } label: {
                        Image(systemName: ttsEnabled
                            ? "speaker.wave.2.fill" : "speaker.slash")
                    }
                    .accessibilityLabel("Speak translations")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(pipeline.isRunning ? "End" : "Clear") {
                        Task {
                            if pipeline.isRunning { await pipeline.stop() }
                            else { pipeline.store.clear(.conversation) }
                        }
                    }
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
        }
    }

    private var divider: some View {
        HStack {
            VStack { Divider() }
            Image(systemName: "globe")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            VStack { Divider() }
        }
        .padding(.horizontal)
    }

    private var languagePickers: some View {
        Menu {
            Picker("I speak", selection: $myLanguage) {
                ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("They speak", selection: $theirLanguage) {
                ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
            }
        } label: {
            Label(
                "\(myLanguage.displayName) ⇄ \(theirLanguage.displayName)",
                systemImage: "globe")
        }
        .disabled(pipeline.isRunning)
    }

    private func claimTurn(_ direction: LanguagePair) {
        Task {
            guard myLanguage != theirLanguage else {
                errorMessage = "Choose two different languages."
                return
            }
            do {
                // A running captions session can't be morphed into a
                // conversation by switching turns — end it and start fresh.
                if pipeline.isRunning, pipeline.sessionMode != .conversation {
                    await pipeline.stop()
                }
                if !pipeline.isRunning {
                    guard await AudioCaptureService.requestPermission() else {
                        errorMessage = "Microphone access is required. Enable it in Settings."
                        return
                    }
                    try await pipeline.start(
                        direction: direction,
                        allDirections: [outgoing, incoming])
                } else if pipeline.activeDirection == direction {
                    // Tapping your own live mic ends the session politely.
                    await pipeline.stop()
                } else {
                    Haptics.turnSwitch()
                    try await pipeline.switchDirection(to: direction)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// One speaker's half: a header naming their language, their view of the
/// conversation, and a mic button for their turns.
private struct ConversationHalf: View {
    let pipeline: CaptionPipeline
    let speaksIn: AppLanguage
    /// The direction active when this side is talking.
    let direction: LanguagePair
    let onTapMic: () -> Void

    private var isLive: Bool {
        pipeline.isRunning && pipeline.activeDirection == direction
    }

    /// The other side of this conversation is live.
    private var otherIsLive: Bool {
        pipeline.isRunning && pipeline.activeDirection == direction.reversed
    }

    var body: some View {
        VStack(spacing: 6) {
            header

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(visibleEntries) { entry in
                            ConversationBubble(entry: entry, readerLanguage: speaksIn)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: visibleEntries.last?.displayTranslation) {
                    if let last = visibleEntries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            LiveLevelMicButton(pipeline: pipeline, isLive: isLive, size: 60) {
                onTapMic()
            }
            Text(hint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(height: 14)
                .padding(.bottom, 6)
        }
        .frame(maxHeight: .infinity)
    }

    private var visibleEntries: [CaptionEntry] {
        pipeline.store.entries(in: .conversation).filter { entry in
            if entry.direction.source == speaksIn { return true }
            // Incoming speech appears once readable — or failed, so the
            // reader at least sees that something was said.
            return entry.direction.target == speaksIn
                && (entry.displayTranslation != nil || entry.draftFailed)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(speaksIn.displayName)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            if isLive {
                Image(systemName: "waveform")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .symbolEffect(.variableColor, isActive: true)
            }
        }
        .padding(.top, 6)
    }

    private var hint: String {
        if isLive { return speaksIn.listeningLabel }
        if otherIsLive { return "" }
        return speaksIn.tapToTalkLabel
    }
}

/// Chat-style bubble. Own speech sits trailing in a tinted bubble; what the
/// other person said arrives leading, translated, in a neutral bubble.
private struct ConversationBubble: View {
    let entry: CaptionEntry
    let readerLanguage: AppLanguage

    private var isOwnSpeech: Bool { entry.direction.source == readerLanguage }

    var body: some View {
        HStack {
            if isOwnSpeech { Spacer(minLength: 40) }

            Group {
                if isOwnSpeech {
                    Text(entry.sourceText)
                        .font(.callout)
                        .opacity(entry.state == .volatile ? 0.55 : 1)
                } else if let translation = entry.displayTranslation {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(translation)
                            .font(.title3.weight(.medium))
                            .contentTransition(.opacity)
                        if entry.state == .refining {
                            Image(systemName: "sparkles")
                                .font(.caption2)
                                .foregroundStyle(.tint)
                                .symbolEffect(.pulse, isActive: true)
                        }
                    }
                } else if entry.draftFailed {
                    Label(entry.sourceText, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isOwnSpeech
                    ? AnyShapeStyle(Color.accentColor.opacity(0.14))
                    : AnyShapeStyle(Color(.secondarySystemBackground)),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if !isOwnSpeech { Spacer(minLength: 40) }
        }
        .animation(.easeInOut(duration: 0.25), value: entry.displayTranslation)
    }
}
