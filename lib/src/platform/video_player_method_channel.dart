import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/native_video_player_quality.dart';
import '../models/native_video_player_subtitle_track.dart';
import '../models/native_video_player_track_disable_result.dart';

/// Handles all method channel communication with the native platform
class VideoPlayerMethodChannel {
  VideoPlayerMethodChannel({required this.primaryPlatformViewId})
    : _methodChannel = const MethodChannel('native_video_player');

  final int primaryPlatformViewId;
  final MethodChannel _methodChannel;

  /// Loads a video URL
  Future<void> load({
    required String url,
    required bool autoPlay,
    Map<String, String>? headers,
    Map<String, dynamic>? mediaInfo,
    Map<String, dynamic>? drmConfig,
  }) async {
    final Map<String, Object> params = <String, Object>{
      'url': url,
      'autoPlay': autoPlay,
      'viewId': primaryPlatformViewId,
    };

    if (headers != null) {
      params['headers'] = headers;
    }

    if (mediaInfo != null) {
      params['mediaInfo'] = mediaInfo;
    }

    if (drmConfig != null) {
      params['drmConfig'] = drmConfig;
    }

    await _methodChannel.invokeMethod<void>('load', params);
  }

  /// Starts or resumes video playback
  Future<void> play() async {
    try {
      await _methodChannel.invokeMethod<void>('play', <String, Object>{
        'viewId': primaryPlatformViewId,
      });
    } catch (e) {
      // Silently handle errors
    }
  }

  /// Pauses video playback
  Future<void> pause() async {
    try {
      await _methodChannel.invokeMethod<void>('pause', <String, Object>{
        'viewId': primaryPlatformViewId,
      });
    } catch (e) {
      debugPrint('Error calling pause: $e');
    }
  }

  /// Seeks to a specific position
  Future<void> seekTo(Duration position) async {
    try {
      await _methodChannel.invokeMethod<void>('seekTo', <String, Object>{
        'viewId': primaryPlatformViewId,
        'milliseconds': position.inMilliseconds,
      });
    } catch (e) {
      debugPrint('Error calling seekTo: $e');
    }
  }

  /// Sets the volume
  Future<void> setVolume(double volume) async {
    try {
      await _methodChannel.invokeMethod<void>('setVolume', <String, Object>{
        'viewId': primaryPlatformViewId,
        'volume': volume,
      });
    } catch (e) {
      debugPrint('Error calling setVolume: $e');
    }
  }

  /// Sets the playback speed
  Future<void> setSpeed(double speed) async {
    try {
      await _methodChannel.invokeMethod<void>('setSpeed', <String, Object>{
        'viewId': primaryPlatformViewId,
        'speed': speed,
      });
    } catch (e) {
      debugPrint('Error calling setSpeed: $e');
    }
  }

  /// Sets whether the video should loop
  Future<void> setLooping(bool looping) async {
    try {
      await _methodChannel.invokeMethod<void>('setLooping', <String, Object>{
        'viewId': primaryPlatformViewId,
        'looping': looping,
      });
    } catch (e) {
      debugPrint('Error calling setLooping: $e');
    }
  }

  /// Sets the video quality
  Future<void> setQuality(NativeVideoPlayerQuality quality) async {
    try {
      final Map<String, Object> params = <String, Object>{
        'viewId': primaryPlatformViewId,
        'quality': quality.toMap(),
      };
      await _methodChannel.invokeMethod<void>('setQuality', params);
    } catch (e) {
      debugPrint('Error calling setQuality: $e');
    }
  }

  /// Gets available video qualities
  Future<List<NativeVideoPlayerQuality>> getAvailableQualities() async {
    try {
      final dynamic result = await _methodChannel.invokeMethod<dynamic>(
        'getAvailableQualities',
        <String, Object>{'viewId': primaryPlatformViewId},
      );
      if (result is List) {
        final qualities = result
            .map(
              (dynamic e) =>
                  NativeVideoPlayerQuality.fromMap(e as Map<dynamic, dynamic>),
            )
            .toList();
        return qualities;
      }
      debugPrint('No qualities found in result');
      return <NativeVideoPlayerQuality>[];
    } catch (e) {
      debugPrint('Error fetching qualities: $e');
      return <NativeVideoPlayerQuality>[];
    }
  }

  /// Gets available subtitle tracks
  Future<List<NativeVideoPlayerSubtitleTrack>>
  getAvailableSubtitleTracks() async {
    try {
      final dynamic result = await _methodChannel.invokeMethod<dynamic>(
        'getAvailableSubtitleTracks',
        <String, Object>{'viewId': primaryPlatformViewId},
      );
      if (result is List) {
        final tracks = result
            .map(
              (dynamic e) => NativeVideoPlayerSubtitleTrack.fromMap(
                e as Map<dynamic, dynamic>,
              ),
            )
            .toList();
        return tracks;
      }
      debugPrint('No subtitle tracks found in result');
      return <NativeVideoPlayerSubtitleTrack>[];
    } catch (e) {
      debugPrint('Error fetching subtitle tracks: $e');
      return <NativeVideoPlayerSubtitleTrack>[];
    }
  }

  /// Sets the subtitle track
  /// Pass a track with index -1 or use NativeVideoPlayerSubtitleTrack.off() to disable subtitles
  Future<void> setSubtitleTrack(NativeVideoPlayerSubtitleTrack track) async {
    try {
      final Map<String, Object> params = <String, Object>{
        'viewId': primaryPlatformViewId,
        'track': track.toMap(),
      };
      await _methodChannel.invokeMethod<void>('setSubtitleTrack', params);
    } catch (e) {
      debugPrint('Error calling setSubtitleTrack: $e');
    }
  }

  /// Disables or enables the video track in the native player.
  ///
  /// When [disabled] is true, the native player stops downloading video segments
  /// from HLS demuxed streams, saving bandwidth during background playback.
  /// Audio continues uninterrupted.
  ///
  /// When [disabled] is false, video segment downloads resume from the current position.
  ///
  /// Returns a [VideoTrackDisableResult] describing what happened:
  /// - [VideoTrackDisableStatus.ok] — the toggle was applied.
  /// - [VideoTrackDisableStatus.skippedNoDemuxedAudio] — the stream has no
  ///   separate audio rendition, so disabling video would kill audio too.
  ///   The caller should either pick a different stream or not disable.
  /// Propagates [PlatformException] on native errors so callers can react.
  Future<VideoTrackDisableResult> setVideoTrackDisabled(bool disabled) async {
    final dynamic result = await _methodChannel.invokeMethod<dynamic>(
      'setVideoTrackDisabled',
      <String, Object>{
        'viewId': primaryPlatformViewId,
        'disabled': disabled,
      },
    );
    if (result is Map && result['skipped'] == true) {
      final reason = result['reason'];
      if (reason == 'no_demuxed_audio') {
        return const VideoTrackDisableResult(
          VideoTrackDisableStatus.skippedNoDemuxedAudio,
        );
      }
      return const VideoTrackDisableResult(VideoTrackDisableStatus.skipped);
    }
    return const VideoTrackDisableResult(VideoTrackDisableStatus.ok);
  }

  /// Starts or stops the foreground media notification for background playback.
  Future<void> setBackgroundPlaybackActive(bool active) {
    return _methodChannel.invokeMethod<void>(
      'setBackgroundPlaybackActive',
      <String, Object>{
        'viewId': primaryPlatformViewId,
        'active': active,
      },
    );
  }

  /// Hides or restores the lock-screen / notification "Now Playing" entry for
  /// the current media without stopping playback.
  ///
  /// When [suppressed] is true, the native media notification / Control Center
  /// info is cleared but playback continues; when false, it is republished.
  /// Used when the floating player is hidden behind another surface (the sleep
  /// mixer) so the OS controls don't linger on a track the user can't see.
  Future<void> setNowPlayingSuppressed(bool suppressed) async {
    await _methodChannel.invokeMethod<dynamic>(
      'setNowPlayingSuppressed',
      <String, Object>{
        'viewId': primaryPlatformViewId,
        'suppressed': suppressed,
      },
    );
  }

  /// Checks if Picture-in-Picture is available
  Future<bool> isPictureInPictureAvailable() async {
    try {
      final dynamic result = await _methodChannel.invokeMethod<dynamic>(
        'isPictureInPictureAvailable',
        <String, Object>{'viewId': primaryPlatformViewId},
      );
      return result == true;
    } catch (e) {
      debugPrint('Error checking PiP availability: $e');
      return false;
    }
  }

  /// Enters Picture-in-Picture mode
  Future<bool> enterPictureInPicture() async {
    try {
      final dynamic result = await _methodChannel.invokeMethod<dynamic>(
        'enterPictureInPicture',
        <String, Object>{'viewId': primaryPlatformViewId},
      );
      return result == true;
    } catch (e) {
      debugPrint('Error calling enterPictureInPicture: $e');
      return false;
    }
  }

  /// Exits Picture-in-Picture mode
  Future<bool> exitPictureInPicture() async {
    try {
      final dynamic result = await _methodChannel.invokeMethod<dynamic>(
        'exitPictureInPicture',
        <String, Object>{'viewId': primaryPlatformViewId},
      );
      return result == true;
    } catch (e) {
      debugPrint('Error calling exitPictureInPicture: $e');
      return false;
    }
  }

  /// Enables automatic inline Picture-in-Picture mode (iOS 14.2+)
  Future<bool> enableAutomaticInlinePip() async {
    try {
      final dynamic result = await _methodChannel.invokeMethod<dynamic>(
        'enableAutomaticInlinePip',
        <String, Object>{'viewId': primaryPlatformViewId},
      );
      return result == true;
    } catch (e) {
      debugPrint('Error calling enableAutomaticInlinePip: $e');
      return false;
    }
  }

  /// Arms auto-PiP on the inline or Dart-fullscreen (floating) view (iOS 14.2+)
  ///
  /// [controllerId], when provided, lets the native dispatcher fall back to any
  /// live view of that controller if [primaryPlatformViewId] is stale (e.g. the
  /// inline view was disposed while the floating preview is on screen). This
  /// call is controller-scoped natively, so any live view of the controller can
  /// service it — without the fallback a stale viewId yields NO_VIEW and the
  /// collapse/expand context is silently lost.
  Future<void> setAutomaticPipView({
    required bool fullscreenContext,
    int? controllerId,
  }) async {
    try {
      await _methodChannel.invokeMethod<void>(
        'setAutomaticPipView',
        <String, Object>{
          // Used by the plugin-level `native_video_player` dispatcher
          // (VideoPlayerViewFactory) to route the call to the right view —
          // NOT read by handleSetAutomaticPipView itself.
          'viewId': primaryPlatformViewId,
          'controllerId': ?controllerId,
          'fullscreenContext': fullscreenContext,
        },
      );
    } catch (e) {
      debugPrint('Error calling setAutomaticPipView: $e');
    }
  }

  /// Disables automatic inline Picture-in-Picture mode (iOS 14.2+)
  Future<bool> disableAutomaticInlinePip() async {
    try {
      final dynamic result = await _methodChannel.invokeMethod<dynamic>(
        'disableAutomaticInlinePip',
        <String, Object>{'viewId': primaryPlatformViewId},
      );
      return result == true;
    } catch (e) {
      debugPrint('Error calling disableAutomaticInlinePip: $e');
      return false;
    }
  }

  /// Hard-toggles AVKit's `allowsPictureInPicturePlayback`. `false` blocks all
  /// PIP entry paths and survives view reconstruction (vs the lighter-weight
  /// [enableAutomaticInlinePip] / [disableAutomaticInlinePip]).
  Future<bool> setAllowsPictureInPicture(bool allows) async {
    try {
      final dynamic result = await _methodChannel.invokeMethod<dynamic>(
        'setAllowsPictureInPicture',
        <String, Object>{
          'viewId': primaryPlatformViewId,
          'allows': allows,
        },
      );
      return result == true;
    } catch (e) {
      debugPrint('Error calling setAllowsPictureInPicture: $e');
      return false;
    }
  }

  /// Toggles AVPlayer's `allowsExternalPlayback` (iOS-only).
  Future<void> setAllowsExternalPlayback(bool allows) async {
    try {
      await _methodChannel.invokeMethod<void>(
        'setAllowsExternalPlayback',
        <String, Object>{
          'viewId': primaryPlatformViewId,
          'allows': allows,
        },
      );
    } catch (e) {
      debugPrint('Error calling setAllowsExternalPlayback: $e');
    }
  }

  /// Toggles `AVPlayerViewController.requiresLinearPlayback` (iOS-only).
  /// When `true`, AVKit hides the scrubber and 15s skip-back/forward
  /// controls in both inline and PIP UIs. No-op on Android.
  Future<void> setRequiresLinearPlayback(bool required) async {
    try {
      await _methodChannel.invokeMethod<void>(
        'setRequiresLinearPlayback',
        <String, Object>{
          'viewId': primaryPlatformViewId,
          'required': required,
        },
      );
    } catch (e) {
      debugPrint('Error calling setRequiresLinearPlayback: $e');
    }
  }

  /// Enters fullscreen mode
  Future<void> enterFullScreen() async {
    try {
      await _methodChannel.invokeMethod<void>(
        'enterFullScreen',
        <String, Object>{'viewId': primaryPlatformViewId},
      );
    } catch (e) {
      debugPrint('Error calling enterFullScreen: $e');
    }
  }

  /// Exits fullscreen mode
  Future<void> exitFullScreen() async {
    try {
      await _methodChannel.invokeMethod<void>(
        'exitFullScreen',
        <String, Object>{'viewId': primaryPlatformViewId},
      );
    } catch (e) {
      debugPrint('Error calling exitFullScreen: $e');
    }
  }

  /// Sets whether native player controls are shown
  Future<void> setShowNativeControls(bool show) async {
    try {
      await _methodChannel.invokeMethod<void>(
        'setShowNativeControls',
        <String, Object>{'viewId': primaryPlatformViewId, 'show': show},
      );
    } catch (e) {
      debugPrint('Error calling setShowNativeControls: $e');
    }
  }

  /// Sets whether video should use aspect-fill (zoom/crop) instead of aspect-fit.
  Future<void> setUseAspectFill(bool enabled) async {
    try {
      await _methodChannel.invokeMethod<void>(
        'setUseAspectFill',
        <String, Object>{'viewId': primaryPlatformViewId, 'enabled': enabled},
      );
    } catch (e) {
      debugPrint('Error calling setUseAspectFill: $e');
    }
  }

  /// Gets current video dimensions if available.
  Future<Map<String, int>?> getVideoDimensions() async {
    try {
      final dynamic result = await _methodChannel.invokeMethod<dynamic>(
        'getVideoDimensions',
        <String, Object>{'viewId': primaryPlatformViewId},
      );
      if (result is Map) {
        final width = (result['width'] as num?)?.toInt();
        final height = (result['height'] as num?)?.toInt();
        if (width != null && height != null && width > 0 && height > 0) {
          return <String, int>{'width': width, 'height': height};
        }
      }
      return null;
    } catch (e) {
      debugPrint('Error calling getVideoDimensions: $e');
      return null;
    }
  }

  /// Checks if AirPlay is available (iOS only)
  Future<bool> isAirPlayAvailable() async {
    try {
      final dynamic result = await _methodChannel.invokeMethod<dynamic>(
        'isAirPlayAvailable',
        <String, Object>{'viewId': primaryPlatformViewId},
      );
      return result == true;
    } catch (e) {
      debugPrint('Error calling isAirPlayAvailable: $e');
      return false;
    }
  }

  /// Shows the AirPlay route picker (iOS only)
  Future<void> showAirPlayPicker() async {
    try {
      await _methodChannel.invokeMethod<void>(
        'showAirPlayPicker',
        <String, Object>{'viewId': primaryPlatformViewId},
      );
    } catch (e) {
      debugPrint('Error calling showAirPlayPicker: $e');
    }
  }

  /// Disconnects from AirPlay (iOS only)
  ///
  /// Stops sending video to the currently connected AirPlay device.
  /// AirPlay can be reconnected again later by the user.
  ///
  /// Throws if not currently connected to AirPlay.
  Future<void> disconnectAirPlay() async {
    try {
      await _methodChannel.invokeMethod<void>(
        'disconnectAirPlay',
        <String, Object>{'viewId': primaryPlatformViewId},
      );
    } catch (e) {
      debugPrint('Error calling disconnectAirPlay: $e');
      rethrow;
    }
  }

  /// Starts AirPlay device detection (iOS only)
  ///
  /// Begins monitoring for available AirPlay devices. This should be called
  /// when you want to start searching for AirPlay devices.
  ///
  /// Note: This is a global operation that affects the entire app.
  Future<void> startAirPlayDetection() async {
    try {
      await _methodChannel.invokeMethod<void>(
        'startAirPlayDetection',
        <String, Object>{'viewId': primaryPlatformViewId},
      );
    } catch (e) {
      debugPrint('Error calling startAirPlayDetection: $e');
      rethrow;
    }
  }

  /// Stops AirPlay device detection (iOS only)
  ///
  /// Stops monitoring for available AirPlay devices. This should be called
  /// when you no longer need to search for AirPlay devices.
  ///
  /// Note: This is a global operation that affects the entire app.
  Future<void> stopAirPlayDetection() async {
    try {
      await _methodChannel.invokeMethod<void>(
        'stopAirPlayDetection',
        <String, Object>{'viewId': primaryPlatformViewId},
      );
    } catch (e) {
      debugPrint('Error calling stopAirPlayDetection: $e');
      rethrow;
    }
  }

  /// Reparents the native player view from Flutter's container to the root
  /// UIViewController's view with Auto Layout constraints (edge-pinned).
  /// Use this before an orientation change so iOS animates the view smoothly.
  Future<void> useNativeLayout() async {
    try {
      await _methodChannel.invokeMethod<void>('useNativeLayout', <String, Object>{
        'viewId': primaryPlatformViewId,
      });
    } catch (e) {
      debugPrint('Error calling useNativeLayout: $e');
    }
  }

  /// Returns the native player view to Flutter's layout control.
  /// Call this after the orientation transition settles.
  Future<void> useFlutterLayout() async {
    try {
      await _methodChannel.invokeMethod<void>('useFlutterLayout', <String, Object>{
        'viewId': primaryPlatformViewId,
      });
    } catch (e) {
      debugPrint('Error calling useFlutterLayout: $e');
    }
  }

  /// Asks the native side to ensure the player surface is connected to this view.
  /// Called when reconnecting after all platform views were disposed (e.g. list→detail→back).
  Future<void> ensureSurfaceConnected() async {
    try {
      await _methodChannel.invokeMethod<void>(
        'ensureSurfaceConnected',
        <String, Object>{'viewId': primaryPlatformViewId},
      );
    } catch (e) {
      debugPrint('Error calling ensureSurfaceConnected: $e');
    }
  }

  /// Refreshes the system media controls (lock-screen / notification next/prev
  /// availability) for the currently-loaded media, without restarting playback.
  ///
  /// Used by playlist hosts after the playing item is reordered/shuffled to a
  /// new position — the `mediaInfo` set at `load` time has gone stale and the
  /// OS-rendered buttons need to follow the item's new queue neighbours.
  ///
  /// Only the two track-navigation booleans are updated; other `mediaInfo`
  /// fields (title, artwork, etc.) are left untouched. No-op on platforms that
  /// don't implement the method (errors are swallowed; callers shouldn't make
  /// this their only path to update controls).
  Future<void> updateTrackNavFlags({
    required bool showSystemNextTrackControl,
    required bool showSystemPreviousTrackControl,
  }) async {
    try {
      await _methodChannel.invokeMethod<void>(
        'updateTrackNavFlags',
        <String, Object>{
          'viewId': primaryPlatformViewId,
          'showSystemNextTrackControl': showSystemNextTrackControl,
          'showSystemPreviousTrackControl': showSystemPreviousTrackControl,
        },
      );
    } catch (e) {
      debugPrint('Error calling updateTrackNavFlags: $e');
    }
  }

  /// Disposes the native player resources
  Future<void> dispose() async {
    try {
      await _methodChannel.invokeMethod<void>('dispose', <String, Object>{
        'viewId': primaryPlatformViewId,
      });
    } catch (e) {
      debugPrint('Error calling dispose: $e');
    }
  }
}
