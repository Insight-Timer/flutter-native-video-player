/// Outcome of a [NativeVideoPlayerController.setVideoTrackDisabled] call.
enum VideoTrackDisableStatus {
  /// The video track was successfully disabled or re-enabled.
  ok,

  /// The stream has no demuxed audio rendition, so disabling the video track
  /// would have killed audio too. No change was applied — the caller should
  /// pick a different stream (e.g. a muxed audio-only variant) or leave video
  /// enabled.
  skippedNoDemuxedAudio,

  /// The native side declined the toggle for an unspecified reason.
  skipped,
}

/// Result of a [NativeVideoPlayerController.setVideoTrackDisabled] call.
class VideoTrackDisableResult {
  const VideoTrackDisableResult(this.status);

  final VideoTrackDisableStatus status;

  bool get wasApplied => status == VideoTrackDisableStatus.ok;
}
