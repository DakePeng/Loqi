import AVFoundation
import Observation
import SwiftUI

/// Playback state for one session recording. Owns the AVAudioPlayer and the
/// audio session category: `.playback` while playing, deactivated on stop so
/// a live recording session can claim the mic again.
@MainActor
@Observable
final class AudioPlaybackController {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var loadError = false

    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    func load(url: URL) {
        guard player?.url != url else { return }
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            self.player = player
            duration = player.duration
            currentTime = 0
            loadError = false
        } catch {
            loadError = true
        }
    }

    func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            ticker?.cancel()
        } else {
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            player.play()
            isPlaying = true
            startTicker()
        }
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = max(0, min(time, duration))
        currentTime = player?.currentTime ?? 0
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying && self.isPlaying {
                    // Reached the end.
                    self.isPlaying = false
                    self.currentTime = 0
                    return
                }
            }
        }
    }
}

/// Play/pause + scrubber row for a saved session's audio. The controller is
/// owned by the detail view so transcript taps can seek the same player;
/// this bar keeps the load/stop lifecycle (it disappears with the view).
struct PlaybackBar: View {
    let url: URL
    let controller: AudioPlaybackController
    @State private var scrubTime: TimeInterval?

    var body: some View {
        HStack(spacing: 12) {
            Button {
                controller.togglePlay()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title)
            }
            .buttonStyle(.plain)
            .disabled(controller.loadError)

            if controller.loadError {
                Text("Recording unavailable")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Slider(
                    value: Binding(
                        get: { scrubTime ?? controller.currentTime },
                        set: { scrubTime = $0 }
                    ),
                    in: 0...max(controller.duration, 0.1)
                ) { editing in
                    if !editing, let scrubTime {
                        controller.seek(to: scrubTime)
                        self.scrubTime = nil
                    }
                }
                Text(timeLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        // Load is idempotent, so reappearing after a scroll is a no-op. No
        // onDisappear stop: this is a lazy List row, and rows "disappear"
        // on mere scrolling — the OWNING view stops the controller when the
        // screen actually goes away.
        .onAppear { controller.load(url: url) }
    }

    private var timeLabel: String {
        let shown = scrubTime ?? controller.currentTime
        return "\(Self.format(shown)) / \(Self.format(controller.duration))"
    }

    private static func format(_ time: TimeInterval) -> String {
        let seconds = Int(time.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
