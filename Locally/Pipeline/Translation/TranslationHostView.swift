import SwiftUI
import Translation

/// Invisible view whose only job is to host a `.translationTask` and hand
/// the resulting TranslationSession to the coordinator. One instance per
/// active direction, mounted persistently at the root (see RootView).
struct TranslationHostView: View {
    let pair: LanguagePair
    let coordinator: TranslationCoordinator

    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(configuration) { session in
                let box = TranslationSessionBox(session: session)
                // Register FIRST: translate() can itself trigger the pack
                // download, and waiting for prepare() before registering
                // left the whole session source-only while a pack
                // downloaded. prepare() then warms the pack in background.
                await coordinator.register(session: box, for: pair)
                do {
                    try await box.prepare()
                } catch {
                    // Pack download declined/failed; translate calls will
                    // surface the error and the UI shows source-only captions.
                }
                // Keep the closure alive: the session dies when it returns.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3600))
                }
                await coordinator.unregister(pair: pair)
            }
            .onAppear {
                configuration = TranslationSession.Configuration(
                    source: pair.source.translationLanguage,
                    target: pair.target.translationLanguage)
            }
            .onDisappear {
                coordinator.unregister(pair: pair)
            }
    }
}

/// Mounts a host view for every direction the coordinator currently needs.
struct TranslationHostStack: View {
    let coordinator: TranslationCoordinator

    var body: some View {
        ZStack {
            ForEach(Array(coordinator.requiredDirections), id: \.self) { pair in
                TranslationHostView(pair: pair, coordinator: coordinator)
            }
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
