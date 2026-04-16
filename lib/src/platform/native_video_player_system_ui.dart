import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Utility access to plugin-level system UI side effects that apply globally
/// rather than to a specific platform view.
///
/// These methods are safe to call on any platform; the underlying native
/// handlers are currently iOS-only (no-op on Android).
class NativeVideoPlayerSystemUi {
  NativeVideoPlayerSystemUi._();

  static const MethodChannel _channel = MethodChannel('native_video_player');

  /// Commits an iOS scene orientation change while hiding the default
  /// rotation animation (no top-left pivot/skew) on iOS 16+.
  ///
  /// ## How it works
  ///
  /// The native side installs an opaque black `UIView` in the key window
  /// *before* calling `requestGeometryUpdate`. Because the overlay is a
  /// solid colour, the system's rotation animation on it is invisible
  /// (rotating a uniform rectangle looks the same at every angle). The
  /// overlay stays in place until the caller invokes
  /// [removeOrientationOverlay], giving the Dart side time to settle its
  /// layout into the new orientation before the native overlay is lifted.
  ///
  /// The native side also syncs `FlutterViewController._orientationPreferences`
  /// via KVC so the engine's internal state tracks the new orientation
  /// without re-entering its own animated code path.
  ///
  /// ## Typical call sequence
  ///
  /// ```dart
  /// // 1. Show Dart-side transition overlay (e.g. black fade).
  /// beginOrientationTransition();
  /// await Future.delayed(fadeDuration);
  ///
  /// // 2. Request the orientation change — native overlay covers the pivot.
  /// final handled = await NativeVideoPlayerSystemUi
  ///     .setOrientationsWithoutAnimation(orientations);
  /// if (!handled) {
  ///   await SystemChrome.setPreferredOrientations(orientations);
  /// }
  ///
  /// // 3. Wait for the system rotation to commit.
  /// await Future.delayed(postChangeHold);
  ///
  /// // 4. Remove the native overlay — Dart overlay is still visible.
  /// await NativeVideoPlayerSystemUi.removeOrientationOverlay();
  ///
  /// // 5. Fade out the Dart overlay.
  /// endOrientationTransition();
  /// ```
  ///
  /// Returns `true` when the native path fully handled the rotation.
  /// Returns `false` on non-iOS platforms, iOS < 16, or when the native
  /// path failed (e.g. no active foreground scene) — in those cases the
  /// caller should fall back to [SystemChrome.setPreferredOrientations].
  static Future<bool> setOrientationsWithoutAnimation(
    List<DeviceOrientation> orientations,
  ) async {
    if (!_isIOS) return false;
    try {
      final result = await _channel.invokeMethod<bool>(
        'setOrientationsWithoutAnimation',
        <String, Object>{
          'orientations': orientations.map(_encodeOrientation).toList(),
        },
      );
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Removes the opaque native overlay that was installed by
  /// [setOrientationsWithoutAnimation].
  ///
  /// Call this once the Flutter layout has settled into the new orientation
  /// and the Dart-side transition overlay is fully opaque (so the user sees
  /// a seamless handoff from the native overlay to the Dart overlay).
  ///
  /// Safe to call even if no overlay is currently installed (no-op).
  /// On non-iOS platforms this is a no-op.
  static Future<void> removeOrientationOverlay() async {
    if (!_isIOS) return;
    try {
      await _channel.invokeMethod<void>('removeOrientationOverlay');
    } catch (_) {
      // Swallow — overlay will auto-remove after 2 s on the native side.
    }
  }

  static String _encodeOrientation(DeviceOrientation orientation) {
    switch (orientation) {
      case DeviceOrientation.portraitUp:
        return 'portraitUp';
      case DeviceOrientation.portraitDown:
        return 'portraitDown';
      case DeviceOrientation.landscapeLeft:
        return 'landscapeLeft';
      case DeviceOrientation.landscapeRight:
        return 'landscapeRight';
    }
  }

  static bool get _isIOS => defaultTargetPlatform == TargetPlatform.iOS;
}
