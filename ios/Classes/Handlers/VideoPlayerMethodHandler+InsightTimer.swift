import Flutter
import UIKit
import AVKit
import AVFoundation
import MediaPlayer

// Fork-specific method handlers: the floating-player PiP handoff, runtime
// PiP/AirPlay/linear-playback toggles, background audio-only playback and
// Now Playing suppression.
// Split from VideoPlayerMethodHandler.swift for maintainability;
// all members keep full access to VideoPlayerView state.
extension VideoPlayerView {
    /// Points auto-PiP at the inline or Dart-fullscreen view for this controller,
    /// so PiP follows the floating player as it collapses/expands.
    func handleSetAutomaticPipView(call: FlutterMethodCall, result: @escaping FlutterResult) {
        if #available(iOS 14.2, *) {
            let fullscreenContext = (call.arguments as? [String: Any])?["fullscreenContext"] as? Bool ?? false
            if let controllerIdValue = controllerId {
                SharedPlayerManager.shared.setAutomaticPipView(for: controllerIdValue, fullscreenContext: fullscreenContext)
            }
            result(true)
        } else {
            result(FlutterError(code: "NOT_SUPPORTED", message: "Automatic inline PiP requires iOS 14.2+", details: nil))
        }
    }

    /// Toggles `AVPlayerViewController.requiresLinearPlayback` at runtime.
    /// When true, AVKit hides the scrubber and 15s skip controls (inline +
    /// PIP). Hosts use this to gate non-premium users out of seeking.
    func handleSetRequiresLinearPlayback(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let required = args["required"] as? Bool else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing 'required' bool parameter",
                details: nil
            ))
            return
        }
        requiresLinearPlayback = required
        if usesViewControllerDisplay {
            playerViewController.requiresLinearPlayback = required
        }
        fullscreenPlayerViewController?.requiresLinearPlayback = required
        result(nil)
    }

    /// Toggles AVKit's master PIP switch at runtime. Mirrors the setting to
    /// `SharedPlayerManager` so view reconstructions don't revert to the
    /// construction-time default.
    func handleSetAllowsPictureInPicture(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let allows = args["allows"] as? Bool else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing 'allows' bool parameter",
                details: nil
            ))
            return
        }

        applyAllowsPictureInPicture(allows)

        if let controllerIdValue = controllerId {
            SharedPlayerManager.shared.setAllowsPictureInPicture(for: controllerIdValue, allows: allows)
        }

        // Only toggle this view's own automatic-PiP flag — never setAutomaticPiPEnabled,
        // which re-points primary at the inline view and fights setAutomaticPipView.
        if #available(iOS 14.2, *) {
            if !allows {
                setAutomaticInlinePiP(false)
            } else {
                if canStartPictureInPictureAutomatically {
                    setAutomaticInlinePiP(true)
                }

                // Re-apply ~1s later: AVKit can ignore the immediate set during a
                // video media-group restore (audio→video toggle).
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard #available(iOS 14.2, *), let self = self else { return }
                    let stillAllows: Bool
                    if let controllerIdValue = self.controllerId {
                        stillAllows = SharedPlayerManager.shared.getPipSettings(for: controllerIdValue)?.allowsPictureInPicture ?? true
                    } else {
                        stillAllows = self.allowsInlinePictureInPicture
                    }
                    guard stillAllows, self.canStartPictureInPictureAutomatically else { return }
                    self.setAutomaticInlinePiP(true)
                }
            }
        }

        result(true)
    }

    /// Disallowing external playback drops an active AirPlay session to
    /// audio-only: video returns to the device, audio stays on the receiver.
    func handleSetAllowsExternalPlayback(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let allows = args["allows"] as? Bool else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing 'allows' bool parameter",
                details: nil
            ))
            return
        }

        guard let player = player else {
            result(nil)
            return
        }

        player.allowsExternalPlayback = allows
        result(nil)
    }

    // MARK: - Video Track Disabling (Background Audio-Only)

    /// Disables or enables the video track for HLS background audio-only streaming.
    ///
    /// Uses a two-strategy approach:
    /// - Strategy 1 (AVMediaSelectionGroup): Deselects the visual media selection group.
    ///   With demuxed HLS, AVPlayer stops downloading video segments.
    /// - Strategy 2 (preferredPeakBitRate): Fallback that restricts bitrate to exclude video variants.
    ///
    /// When re-enabling, restores default video rendition and clears bitrate restriction.
    func handleSetVideoTrackDisabled(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let disabled = args["disabled"] as? Bool else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing 'disabled' parameter",
                details: nil
            ))
            return
        }

        guard let player = player, let playerItem = player.currentItem else {
            result(nil)
            return
        }

        if disabled {
            // Check if HLS has demuxed (separate) audio tracks.
            // AVMediaSelectionGroup for .audible is non-nil only when
            // #EXT-X-MEDIA:TYPE=AUDIO is present with separate audio renditions.
            // If nil/empty, audio is muxed inside video segments, so skip.
            let hasDemuxedAudio: Bool
            if let asset = playerItem.asset as? AVURLAsset,
               let audioGroup = asset.mediaSelectionGroup(
                   forMediaCharacteristic: .audible
               ),
               !audioGroup.options.isEmpty {
                hasDemuxedAudio = true
            } else {
                hasDemuxedAudio = false
            }

            if !hasDemuxedAudio {
                result([
                    "skipped": true,
                    "reason": "no_demuxed_audio"
                ])
                return
            }

            // Strategy 1: Deselect the visual media selection group (demuxed HLS)
            if let asset = playerItem.asset as? AVURLAsset,
               let videoGroup = asset.mediaSelectionGroup(
                   forMediaCharacteristic: .visual
               ) {
                playerItem.select(nil, in: videoGroup)
            }

            // Strategy 2: Restrict bitrate to audio-only threshold (fallback)
            playerItem.preferredPeakBitRate = 1.0
        } else {
            // Re-enable: restore video rendition selection
            if let asset = playerItem.asset as? AVURLAsset,
               let videoGroup = asset.mediaSelectionGroup(
                   forMediaCharacteristic: .visual
               ) {
                if let defaultOption = videoGroup.defaultOption {
                    playerItem.select(defaultOption, in: videoGroup)
                } else if let firstOption = videoGroup.options.first {
                    playerItem.select(firstOption, in: videoGroup)
                }
            }

            // Clear bitrate restriction (0 = no limit)
            playerItem.preferredPeakBitRate = 0
        }

        result(nil)
    }

    /// Hides or restores this view's lock-screen / Control Center Now Playing
    /// info without stopping playback (see `setNowPlayingSuppressed`).
    func handleSetNowPlayingSuppressed(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let suppressed = args["suppressed"] as? Bool else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing 'suppressed' parameter",
                details: nil
            ))
            return
        }
        setNowPlayingSuppressed(suppressed)
        result(nil)
    }
}
