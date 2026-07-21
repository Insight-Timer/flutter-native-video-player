import AVFoundation
import MediaPlayer
import QuartzCore

// MARK: - AirPlay Seek Clamp
/// AirPlay receivers (e.g. Apple TV) show their own transport UI during external
/// playback, and seeks made there bypass MPRemoteCommandCenter entirely — so media
/// loaded with showSkipControls=false could still be scrubbed from the receiver.
/// There is no public API to disable receiver-side seeking, so while external
/// playback is active we watch the playback position and revert any time jump the
/// app itself didn't request.
extension VideoPlayerView {

    /// Max position drift (seconds) between ticks before a jump counts as a seek.
    private static let seekClampToleranceSeconds: Double = 3.0

    /// How long an app-initiated jump stays accepted, covering seek/load latency.
    private static let seekClampAllowanceSeconds: CFTimeInterval = 3.0

    /// Installs or removes the clamp observer as external playback toggles.
    func updateSeekClampForExternalPlayback(isActive: Bool) {
        if isActive {
            installSeekClampObserver()
        } else {
            removeSeekClampObserver()
        }
    }

    /// Accepts an upcoming app-initiated jump (seek, load, replay) so the clamp
    /// doesn't mistake it for a receiver-initiated seek. Pass nil to rebaseline
    /// from whatever position the player reports next.
    func allowSeekClampJump(to seconds: Double?) {
        seekClampAllowanceDeadline = CACurrentMediaTime() + Self.seekClampAllowanceSeconds
        seekClampBaselineSeconds = seconds
    }

    func removeSeekClampObserver() {
        if let observer = seekClampTimeObserver {
            player?.removeTimeObserver(observer)
            seekClampTimeObserver = nil
            print("🔒 View \(viewId) removed AirPlay seek clamp observer")
        }
        seekClampBaselineSeconds = nil
    }

    private func installSeekClampObserver() {
        guard seekClampTimeObserver == nil, let player = player else { return }

        // Treat the route handoff itself as an allowed jump.
        allowSeekClampJump(to: nil)

        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        seekClampTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            self?.enforceSeekClamp()
        }
        print("🔒 View \(viewId) installed AirPlay seek clamp observer")
    }

    /// Whether the currently loaded media forbids seeking from system surfaces.
    /// Falls back to SharedPlayerManager for views that never ran a load (e.g. a
    /// second platform view created for an already-playing shared controller).
    private var isSeekClampEnforced: Bool {
        guard let player = player, player.isExternalPlaybackActive else { return false }
        var mediaInfo = currentMediaInfo
        if mediaInfo == nil, let controllerIdValue = controllerId {
            mediaInfo = SharedPlayerManager.shared.getMediaInfo(for: controllerIdValue)
        }
        return !((mediaInfo?["showSkipControls"] as? Bool) ?? true)
    }

    /// Periodic tick (also fired by AVPlayer on any time jump, including while
    /// paused): compare the current position against the last known one and
    /// revert receiver-initiated jumps.
    private func enforceSeekClamp() {
        guard !isDisposed, let player = player else { return }

        let seconds = CMTimeGetSeconds(player.currentTime())
        guard seconds.isFinite else { return }

        guard isSeekClampEnforced else {
            seekClampBaselineSeconds = seconds
            return
        }

        // App-initiated jump in flight — accept the new position.
        guard CACurrentMediaTime() >= seekClampAllowanceDeadline else {
            seekClampBaselineSeconds = seconds
            return
        }

        guard let baseline = seekClampBaselineSeconds else {
            seekClampBaselineSeconds = seconds
            return
        }

        if abs(seconds - baseline) > Self.seekClampToleranceSeconds {
            // Keep the baseline so repeated attempts revert to the same position.
            print("🔒 View \(viewId) reverting AirPlay seek: \(seconds)s → \(baseline)s")
            player.seek(
                to: CMTime(seconds: baseline, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            updateNowPlayingPlaybackTime()
        } else {
            seekClampBaselineSeconds = seconds
        }
    }
}
