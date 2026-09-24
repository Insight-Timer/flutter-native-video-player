import MediaPlayer
import AVFoundation

enum NowPlayingOwnership {
    /// Private key stashed into MPNowPlayingInfoCenter.nowPlayingInfo so a view can
    /// recognize its own metadata on dispose. Lets cleanupRemoteCommandOwnership
    /// clear only what it wrote — if another player (audio fork, sibling video
    /// view, ambient mixer) has already overwritten the info, the tag won't match
    /// and the clear is skipped.
    static let key = "co.insight.videoViewId"
}

// MARK: - Remote Command Manager
/// Singleton to manage MPRemoteCommandCenter ownership
/// Ensures only one VideoPlayerView owns the remote commands at a time
class RemoteCommandManager {
    static let shared = RemoteCommandManager()

    /// Track which view currently owns the remote commands
    private var currentOwnerViewId: Int64?

    /// Lock to prevent race conditions during ownership transfer
    private let lock = NSLock()

    private init() {}

    /// Check if a specific view is the current owner
    func isOwner(_ viewId: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentOwnerViewId == viewId
    }

    /// Set a new owner for remote commands
    func setOwner(_ viewId: Int64) {
        lock.lock()
        defer { lock.unlock() }
        currentOwnerViewId = viewId
        print("🎛️ Remote command ownership transferred to view \(viewId)")
    }

    /// Clear ownership (e.g., when owner is disposed)
    func clearOwner(_ viewId: Int64) {
        lock.lock()
        defer { lock.unlock() }
        if currentOwnerViewId == viewId {
            currentOwnerViewId = nil
            print("🎛️ Remote command ownership cleared from view \(viewId)")
        }
    }

    /// Get the current owner view ID
    func getCurrentOwner() -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        return currentOwnerViewId
    }

    /// Remove all remote command targets
    func removeAllTargets() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        print("🎛️ Removed all remote command targets")
    }

    /// Atomically set owner and remove all targets
    /// This prevents race conditions when multiple views try to register concurrently
    func atomicallySetOwnerAndRemoveTargets(_ viewId: Int64) {
        lock.lock()
        defer { lock.unlock() }
        currentOwnerViewId = viewId
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        print("🎛️ Atomically transferred ownership to view \(viewId) and cleared targets")
    }
}

extension VideoPlayerView {
    /// Sets up the Now Playing info for the Control Center and Lock Screen
    func setupNowPlayingInfo(mediaInfo: [String: Any]) {
        // Withhold metadata while suppressed (floating player hidden behind the
        // sleep mixer). restoreNowPlayingIfNeeded clears the flag before calling
        // back in, so a genuine restore isn't blocked.
        if isNowPlayingSuppressed {
            print("🎵 setupNowPlayingInfo skipped for view \(viewId) - Now Playing suppressed")
            return
        }
        print("🎵 setupNowPlayingInfo called for view \(viewId)")
        print("   → Media title: \(mediaInfo["title"] ?? "Unknown")")
        print("   → Current Now Playing info before update: \(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String ?? "nil")")

        // CRITICAL: Ensure audio session is active
        // iOS won't show Now Playing info if the audio session is not active
        activateAudioSessionIfHeld()

        var nowPlayingInfo: [String: Any] = [:]

        // --- Core metadata ---
        if let title = mediaInfo["title"] as? String {
            nowPlayingInfo[MPMediaItemPropertyTitle] = title
        }

        if let subtitle = mediaInfo["subtitle"] as? String {
            nowPlayingInfo[MPMediaItemPropertyArtist] = subtitle
        }

        if let album = mediaInfo["album"] as? String {
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = album
        }

        // --- Playback duration & elapsed time ---
        if let duration = player?.currentItem?.asset.duration {
            let durationSeconds = CMTimeGetSeconds(duration)
            if durationSeconds.isFinite {
                nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = durationSeconds
            }
        }

        if let currentTime = player?.currentTime() {
            let elapsedSeconds = CMTimeGetSeconds(currentTime)
            if elapsedSeconds.isFinite {
                nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedSeconds
            }
        }

        // --- Playback rate (0 = paused, 1 = playing) ---
        let playbackRate = player?.rate ?? 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = playbackRate
        print("   → Playback rate: \(playbackRate)")

        // Tag the info so cleanupRemoteCommandOwnership can tell if this view
        // still owns it at dispose time.
        nowPlayingInfo[NowPlayingOwnership.key] = viewId

        // --- Commit initial metadata immediately (before artwork loads) ---
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        print("   → Now Playing info SET to: \(nowPlayingInfo[MPMediaItemPropertyTitle] ?? "Unknown")")

        // Verify immediately
        let immediateCheck = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String ?? "nil"
        print("   → Verified Now Playing info immediately after set: \(immediateCheck)")

        // Check again after a delay to see if something clears it
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let delayedCheck = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String ?? "nil"
            print("   → Delayed check (0.5s later): Now Playing info is: \(delayedCheck)")
            if delayedCheck == "nil" {
                print("   ⚠️ WARNING: Now Playing info was CLEARED by something after we set it!")
            }

            // Diagnostic: Check audio session state
            let audioSession = AVAudioSession.sharedInstance()
            print("   → Audio session category: \(audioSession.category.rawValue)")
            print("   → Audio session is active: \(audioSession.isOtherAudioPlaying ? "No (other audio playing)" : "Yes")")

            // Diagnostic: Check remote command center
            let commandCenter = MPRemoteCommandCenter.shared()
            print("   → Play command has targets: \(commandCenter.playCommand.isEnabled)")
            print("   → Pause command has targets: \(commandCenter.pauseCommand.isEnabled)")

            // Diagnostic: Dump all Now Playing info
            if let info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                print("   → Complete Now Playing info:")
                for (key, value) in info {
                    print("      • \(key): \(value)")
                }
            } else {
                print("   → Now Playing info is completely nil!")
            }
        }

        // --- Load artwork asynchronously (if available) ---
        if let artworkUrlString = mediaInfo["artworkUrl"] as? String,
           let artworkUrl = URL(string: artworkUrlString) {

            loadArtwork(from: artworkUrl) { [weak self] image in
                guard let self = self,
                      let image = image
                else {
                    return
                }

                var updatedInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                guard let ownerId = updatedInfo[NowPlayingOwnership.key] as? Int64, ownerId == self.viewId else {
                    print("🎵 Dropping late artwork for view \(self.viewId) - no longer owns Now Playing info")
                    return
                }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
                    image
                }
                updatedInfo[MPMediaItemPropertyArtwork] = artwork
                updatedInfo[NowPlayingOwnership.key] = self.viewId
                MPNowPlayingInfoCenter.default().nowPlayingInfo = updatedInfo
            }
        }

        // --- Setup remote commands (if not already done) ---
        setupRemoteCommandCenter()
    }

    /// Loads artwork image from URL
    private func loadArtwork(from url: URL, completion: @escaping (UIImage?) -> Void) {
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data, let image = UIImage(data: data) else {
                completion(nil)
                return
            }
            DispatchQueue.main.async {
                completion(image)
            }
        }
        .resume()
    }

    /// Sets up remote command center for Control Center controls
    /// Only registers if this view should be the owner
    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        let showSkipControls = (currentMediaInfo?["showSkipControls"] as? Bool) ?? true
        let showSystemNextTrackControl = (currentMediaInfo?["showSystemNextTrackControl"] as? Bool) ?? false
        let showSystemPreviousTrackControl = (currentMediaInfo?["showSystemPreviousTrackControl"] as? Bool) ?? false
        let shouldShowTrackNavigation = showSystemNextTrackControl || showSystemPreviousTrackControl

        // Already registered and still the owner: the installed targets are this view's, so
        // there is nothing to redo.
        if hasRegisteredRemoteCommands, RemoteCommandManager.shared.isOwner(viewId) {
            print("🎛️ View \(viewId) already has remote commands registered and is still owner - skipping re-registration")
            return
        }

        // First registration, or a sibling view took ownership and removed this view's targets
        // along the way. Re-taking ownership alone would leave the owner and the installed
        // handlers on different views, and every command would then fail its `isOwner` guard —
        // so fall through and re-register, which restores that pairing.
        print("🎛️ View \(viewId) registering remote commands (first time: \(!hasRegisteredRemoteCommands))")

        // Atomically take ownership and clear all existing targets
        // This prevents race conditions when multiple views try to register concurrently
        RemoteCommandManager.shared.atomicallySetOwnerAndRemoveTargets(viewId)
        hasRegisteredRemoteCommands = true

        // --- Play ---
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }

            // Only handle if we still own the remote commands
            guard RemoteCommandManager.shared.isOwner(self.viewId) else {
                print("⚠️ View \(self.viewId) received play command but is not owner")
                return .commandFailed
            }

            // Suppressed behind another surface (e.g. the sleep mixer): ignore transport commands so
            // a lock-screen / Control Center tap can't resume or scrub a hidden video. Mirrors the
            // audio plugin disabling its controls while suppressed.
            if self.isNowPlayingSuppressed { return .commandFailed }

            // Ensure audio session is active before resuming playback
            // This is critical after interruptions (e.g., phone calls)
            self.prepareAudioSession()

            self.player?.play()
            self.sendEvent("play")
            self.updateNowPlayingPlaybackTime()
            return .success
        }

        // --- Pause ---
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }

            // Only handle if we still own the remote commands
            guard RemoteCommandManager.shared.isOwner(self.viewId) else {
                print("⚠️ View \(self.viewId) received pause command but is not owner")
                return .commandFailed
            }

            if self.isNowPlayingSuppressed { return .commandFailed }

            self.player?.pause()
            self.sendEvent("pause")
            self.updateNowPlayingPlaybackTime()
            return .success
        }

        // --- Track navigation and seek controls ---
        // When track navigation is active, a disabled direction falls back to the corresponding seek button
        commandCenter.previousTrackCommand.isEnabled = shouldShowTrackNavigation && showSystemPreviousTrackControl
        commandCenter.nextTrackCommand.isEnabled = shouldShowTrackNavigation && showSystemNextTrackControl
        commandCenter.skipBackwardCommand.isEnabled = shouldShowTrackNavigation ? (!showSystemPreviousTrackControl && showSkipControls) : showSkipControls
        commandCenter.skipForwardCommand.isEnabled = shouldShowTrackNavigation ? (!showSystemNextTrackControl && showSkipControls) : showSkipControls
        commandCenter.changePlaybackPositionCommand.isEnabled = showSkipControls
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.preferredIntervals = [15]

        // Always register all handlers so they're available when controls are toggled via isEnabled
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }

            guard RemoteCommandManager.shared.isOwner(self.viewId) else {
                print("⚠️ View \(self.viewId) received previous track command but is not owner")
                return .commandFailed
            }

            if self.isNowPlayingSuppressed { return .commandFailed }

            self.sendEvent("previousTrack")
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }

            guard RemoteCommandManager.shared.isOwner(self.viewId) else {
                print("⚠️ View \(self.viewId) received next track command but is not owner")
                return .commandFailed
            }

            if self.isNowPlayingSuppressed { return .commandFailed }

            self.sendEvent("nextTrack")
            return .success
        }

        commandCenter.skipForwardCommand.addTarget { [weak self] event in
            guard let self = self,
                  let skipEvent = event as? MPSkipIntervalCommandEvent,
                  let player = self.player
            else {
                return .commandFailed
            }

            guard RemoteCommandManager.shared.isOwner(self.viewId) else {
                print("⚠️ View \(self.viewId) received skip forward command but is not owner")
                return .commandFailed
            }

            if self.isNowPlayingSuppressed { return .commandFailed }

            let currentTime = player.currentTime()
            let newTime = CMTimeAdd(currentTime, CMTime(seconds: skipEvent.interval, preferredTimescale: 600))
            player.seek(to: newTime)
            self.updateNowPlayingPlaybackTime()
            return .success
        }

        commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            guard let self = self,
                  let skipEvent = event as? MPSkipIntervalCommandEvent,
                  let player = self.player
            else {
                return .commandFailed
            }

            guard RemoteCommandManager.shared.isOwner(self.viewId) else {
                print("⚠️ View \(self.viewId) received skip backward command but is not owner")
                return .commandFailed
            }

            if self.isNowPlayingSuppressed { return .commandFailed }

            let currentTime = player.currentTime()
            let newTime = CMTimeSubtract(currentTime, CMTime(seconds: skipEvent.interval, preferredTimescale: 600))
            player.seek(to: max(newTime, .zero))
            self.updateNowPlayingPlaybackTime()
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let seekEvent = event as? MPChangePlaybackPositionCommandEvent,
                  let player = self.player
            else {
                return .commandFailed
            }

            guard RemoteCommandManager.shared.isOwner(self.viewId) else {
                print("⚠️ View \(self.viewId) received change position command but is not owner")
                return .commandFailed
            }

            if self.isNowPlayingSuppressed { return .commandFailed }

            let durationSeconds = CMTimeGetSeconds(player.currentItem?.duration ?? .zero)
            let boundedPosition = max(0, seekEvent.positionTime)

            if durationSeconds.isFinite {
                player.seek(to: CMTime(seconds: min(boundedPosition, durationSeconds), preferredTimescale: 600))
            } else {
                player.seek(to: CMTime(seconds: boundedPosition, preferredTimescale: 600))
            }

            self.updateNowPlayingPlaybackTime()
            return .success
        }

        print("🎛️ View \(viewId) registered remote command handlers")

        // Verify remote commands are enabled
        print("   → Play command enabled: \(commandCenter.playCommand.isEnabled)")
        print("   → Pause command enabled: \(commandCenter.pauseCommand.isEnabled)")
        print("   → Previous track enabled: \(commandCenter.previousTrackCommand.isEnabled)")
        print("   → Next track enabled: \(commandCenter.nextTrackCommand.isEnabled)")
        print("   → Skip forward enabled: \(commandCenter.skipForwardCommand.isEnabled)")
        print("   → Skip backward enabled: \(commandCenter.skipBackwardCommand.isEnabled)")
    }

    /// Refreshes the lock-screen / Control Center prev/next button availability
    /// against the latest track-navigation flags without touching the registered
    /// command targets or the Now Playing info.
    ///
    /// Playlist hosts call this after a reorder/shuffle moves the playing item:
    /// the flags baked into the original `mediaInfo` at `load` time go stale,
    /// and `MPRemoteCommandCenter.{previousTrack,nextTrack}Command.isEnabled`
    /// needs to be re-evaluated against the item's new queue neighbours.
    ///
    /// Mutates the stored `currentMediaInfo` so subsequent reads (e.g. a later
    /// `setupRemoteCommandCenter` call after an ownership transfer) see the
    /// refreshed flags. Skipped when this view doesn't currently own the
    /// command center — toggling buttons we don't own would clobber another
    /// player's controls.
    func refreshSystemTrackControlsAvailability(
        showSystemNextTrackControl: Bool,
        showSystemPreviousTrackControl: Bool
    ) {
        var mediaInfo = currentMediaInfo ?? [:]
        mediaInfo["showSystemNextTrackControl"] = showSystemNextTrackControl
        mediaInfo["showSystemPreviousTrackControl"] = showSystemPreviousTrackControl
        currentMediaInfo = mediaInfo

        guard RemoteCommandManager.shared.isOwner(viewId) else {
            print("🎛️ View \(viewId) refreshSystemTrackControlsAvailability skipped — not owner")
            return
        }

        let showSkipControls = (currentMediaInfo?["showSkipControls"] as? Bool) ?? true
        let shouldShowTrackNavigation = showSystemNextTrackControl || showSystemPreviousTrackControl
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.previousTrackCommand.isEnabled = shouldShowTrackNavigation && showSystemPreviousTrackControl
        commandCenter.nextTrackCommand.isEnabled = shouldShowTrackNavigation && showSystemNextTrackControl
        commandCenter.skipBackwardCommand.isEnabled = shouldShowTrackNavigation
            ? (!showSystemPreviousTrackControl && showSkipControls)
            : showSkipControls
        commandCenter.skipForwardCommand.isEnabled = shouldShowTrackNavigation
            ? (!showSystemNextTrackControl && showSkipControls)
            : showSkipControls
        print("🎛️ View \(viewId) refreshed track-nav availability — prev: \(commandCenter.previousTrackCommand.isEnabled), next: \(commandCenter.nextTrackCommand.isEnabled)")
    }

    /// Updates playback time and rate dynamically (e.g., every second or on state change)
    func updateNowPlayingPlaybackTime() {
        // Don't re-populate metadata we deliberately hid while suppressed.
        if isNowPlayingSuppressed {
            return
        }
        guard let player = player else {
            return
        }

        let isPlaying = player.rate > 0

        // Only allow updates if this view owns the remote commands
        // This prevents multiple views from fighting over Now Playing info
        guard RemoteCommandManager.shared.isOwner(viewId) else {
            if isPlaying {
                print("⚠️ View \(viewId) is playing but doesn't own remote commands")
            }
            return
        }

        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]

        let currentTime = player.currentTime()
        let elapsedSeconds = CMTimeGetSeconds(currentTime)
        if elapsedSeconds.isFinite {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedSeconds
        }

        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = player.rate
        nowPlayingInfo[NowPlayingOwnership.key] = viewId
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    /// Hides or restores this view's Now Playing metadata without stopping
    /// playback. Used when the floating player is hidden behind another surface
    /// (the sleep mixer): the OS lock-screen / Control Center entry should not
    /// linger on a track the user can no longer see, but the audio/video keeps
    /// running so it can be revealed again on return.
    func setNowPlayingSuppressed(_ suppressed: Bool) {
        // Apply to every view of this shared controller: the floating player can
        // hold a sibling view (see FLTR-20586), and any of them may currently own
        // the Now Playing info. Flag them all so none republishes while suppressed.
        var controllerViews: [VideoPlayerView] = [self]
        if let controllerIdValue = controllerId {
            for view in SharedPlayerManager.shared.findAllViewsForController(controllerIdValue)
            where view.viewId != viewId {
                controllerViews.append(view)
            }
        }

        for view in controllerViews {
            view.isNowPlayingSuppressed = suppressed
        }

        if suppressed {
            // Identity-guarded clear: only wipe the info if it belongs to one of
            // this controller's views, so a player that has since taken over
            // (audio fork, ambient mixer) keeps its own.
            let currentInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo
            let controllerViewIds = Set(controllerViews.map { $0.viewId })
            if let ownerId = currentInfo?[NowPlayingOwnership.key] as? Int64, controllerViewIds.contains(ownerId) {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                print("🙈 View \(viewId) suppressed Now Playing info")
            }
        } else if let mediaInfo = currentMediaInfo {
            // Flags are already cleared above, so setupNowPlayingInfo republishes
            // from this (the current primary/rendering) view.
            print("👀 View \(viewId) restoring Now Playing info")
            setupNowPlayingInfo(mediaInfo: mediaInfo)
            updateNowPlayingPlaybackTime()
        }
    }
}
