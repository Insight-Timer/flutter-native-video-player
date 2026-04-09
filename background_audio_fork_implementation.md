# Background Audio-Only HLS Streaming — Fork Implementation Guide

> **Repo:** `https://github.com/Insight-Timer/flutter-native-video-player.git`  
> **Branch:** Create `feature/background-audio-only` from latest main  
> **Scope:** Native Android (Kotlin), Native iOS (Swift), Flutter package (Dart)

---

## 1. Goal

Add a new `setVideoTrackDisabled(bool)` API to the `better_native_video_player` package. When called with `true`, the native player stops downloading video segments from HLS demuxed streams while audio continues uninterrupted. When called with `false`, video resumes.

Additionally, ensure the Android `VideoPlayerMediaSessionService` is properly started as a foreground service so the process survives background execution limits.

---

## 2. Existing Pattern to Follow

The **subtitle track disabling** already demonstrates the exact pattern for all three layers. Follow it as a template:

### Android — `VideoPlayerMethodHandler.kt`

```kotlin
// Existing subtitle disabling (lines 788-872)
val parametersBuilder = player.trackSelectionParameters.buildUpon()
parametersBuilder.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
player.trackSelectionParameters = parametersBuilder.build()
```

### Flutter — `video_player_method_channel.dart`

```dart
// Existing subtitle track method
Future<void> setSubtitleTrack(NativeVideoPlayerSubtitleTrack track) async {
  await _methodChannel.invokeMethod<void>('setSubtitleTrack', <String, Object>{
    'viewId': primaryPlatformViewId,
    'track': track.toMap(),
  });
}
```

### Flutter — `native_video_player_controller.dart`

```dart
// Existing subtitle method
Future<void> setSubtitleTrack(NativeVideoPlayerSubtitleTrack track) async {
  await _methodChannel?.setSubtitleTrack(track);
}
```

---

## 3. Android — Add `handleSetVideoTrackDisabled`

### 3.1 File: `android/src/main/kotlin/com/huddlecommunity/better_native_video_player/handlers/VideoPlayerMethodHandler.kt`

**Step 1:** Add method case in the `handleMethodCall` switch statement. Find the `"setSubtitleTrack"` case and add after it:

```kotlin
"setVideoTrackDisabled" -> handleSetVideoTrackDisabled(call, result)
```

**Step 2:** Add the handler method. Place it after the subtitle methods section (after line ~872):

```kotlin
/**
 * Disables or enables the video track.
 *
 * When disabled on a demuxed HLS stream, ExoPlayer stops selecting video renditions
 * and only fetches audio segments — saving bandwidth during background playback.
 *
 * When re-enabled, ExoPlayer resumes video segment downloads from the current position.
 *
 * On muxed content (progressive MP4), disabling stops video decoding but the full
 * muxed file is still downloaded — no bandwidth savings.
 *
 * Uses the same trackSelectionParameters API as subtitle disabling.
 */
private fun handleSetVideoTrackDisabled(call: MethodCall, result: MethodChannel.Result) {
    try {
        val args = call.arguments as? Map<*, *>
        val disabled = args?.get("disabled") as? Boolean ?: false

        Log.d(TAG, "Setting video track disabled: $disabled")

        val newParameters = player.trackSelectionParameters
            .buildUpon()
            .setTrackTypeDisabled(C.TRACK_TYPE_VIDEO, disabled)
            .build()

        player.trackSelectionParameters = newParameters

        Log.d(TAG, "Video track ${if (disabled) "disabled" else "enabled"}")
        result.success(null)
    } catch (e: Exception) {
        Log.e(TAG, "Error setting video track disabled: ${e.message}", e)
        result.error("ERROR", "Failed to set video track disabled: ${e.message}", null)
    }
}
```

### 3.2 Why No Other Android Files Need Changes

| File | Why no change needed |
|------|---------------------|
| `SharedPlayerManager.kt` | ExoPlayer is created without a custom `DefaultTrackSelector`. The `trackSelectionParameters` API works on the implicit default track selector — same as subtitle disabling. |
| `VideoPlayerView.kt` | `handleMethodCall` at line 382 already delegates unrecognized methods to `methodHandler.handleMethodCall(call, result)`. The new method is automatically routed. |
| `VideoPlayerObserver.kt` | No new events to emit. Track disabling is fire-and-forget. |
| `VideoPlayerEventHandler.kt` | No new events needed. |
| `AndroidManifest.xml` | Already declares `foregroundServiceType="mediaPlayback"`, `FOREGROUND_SERVICE`, and `FOREGROUND_SERVICE_MEDIA_PLAYBACK`. |

---

## 4. Android — Start Foreground Service

### 4.1 Problem

The `VideoPlayerMediaSessionService` is declared in AndroidManifest with all required attributes:

```xml
<!-- Already in AndroidManifest.xml -->
<service
    android:name="...VideoPlayerMediaSessionService"
    android:exported="false"
    android:foregroundServiceType="mediaPlayback">
    <intent-filter>
        <action android:name="androidx.media3.session.MediaSessionService" />
    </intent-filter>
</service>
```

And permissions are declared:

```xml
<!-- Already in AndroidManifest.xml -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />
```

**But the service is never started via `startForegroundService()`.** Without this, Android's background execution limits (API 26+) will kill the process within ~1 minute of backgrounding. Audio stops.

**Reference:** The audio player's `InsightMediaSessionService` (in the main app's `packages/insight_timer_player`) explicitly calls `startForeground(NOTIFICATION_ID, notification)` at line 519 — that's what keeps audio content alive in the background.

### 4.2 File: `android/src/main/kotlin/com/huddlecommunity/better_native_video_player/handlers/VideoPlayerNotificationHandler.kt`

**In the `setupMediaSession()` method**, after the MediaSession is created and stored (around line 352 where `VideoPlayerMediaSessionService.setMediaSession(mediaSession)` is called), add:

```kotlin
// Store the session for the service to access
VideoPlayerMediaSessionService.setMediaSession(mediaSession)

// Start the MediaSessionService as a foreground service.
// When MediaSessionService receives onStartCommand() and onGetSession() returns
// a non-null MediaSession with active media, Media3 internally calls startForeground()
// with the notification it constructs. We just need to start the service.
val serviceIntent = Intent(context, VideoPlayerMediaSessionService::class.java)
if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
    context.startForegroundService(serviceIntent)
} else {
    context.startService(serviceIntent)
}
Log.d(TAG, "Started VideoPlayerMediaSessionService as foreground service")
```

**Add imports if not already present:**

```kotlin
import android.content.Intent
import android.os.Build
```

### 4.3 How It Works End-to-End

```
1. setupMediaSession() creates MediaSession with player + metadata
2. VideoPlayerMediaSessionService.setMediaSession(session) stores it statically
3. context.startForegroundService(intent) starts the service
4. Android calls VideoPlayerMediaSessionService.onStartCommand()
5. Media3 calls onGetSession() → returns the stored MediaSession
6. Media3 internally calls startForeground() with a notification
7. The notification shows title, artwork, and media controls
8. Process stays alive in background ✓
```

### 4.4 Notification Controls — Already Working

The existing `VideoPlayerNotificationHandler` already provides:

| Control | Implementation |
|---------|---------------|
| Play/Pause | Default MediaSession play/pause command |
| Skip Forward (15s) | `NotificationPlayerCustomCommandButton.FORWARD` |
| Skip Backward (15s) | `NotificationPlayerCustomCommandButton.REWIND` |
| Previous Track | `NotificationPlayerCustomCommandButton.PREVIOUS` |
| Next Track | `NotificationPlayerCustomCommandButton.NEXT` |
| Artwork | Async loaded from URL via `loadArtwork()` |
| Title/Subtitle | From `mediaInfo` map passed to `setupMediaSession()` |

**No additional notification changes needed.** All controls continue working during background audio because they communicate with the ExoPlayer instance which stays alive via the foreground service.

---

## 5. iOS — Add `handleSetVideoTrackDisabled`

### 5.1 File: `ios/Classes/Handlers/VideoPlayerMethodHandler.swift`

**Step 1:** Add method case in the `handleMethodCall` switch (before `default:`):

```swift
case "setVideoTrackDisabled":
    handleSetVideoTrackDisabled(call: call, result: result)
```

**Step 2:** Add the handler method:

```swift
// MARK: - Video Track Disabling (Background Audio-Only)

/// Disables or enables the video track for HLS background audio-only streaming.
///
/// Uses a two-strategy approach:
///
/// **Strategy 1 — AVMediaSelectionGroup** (primary, for demuxed HLS):
/// Deselects the visual media selection group entirely. With demuxed HLS
/// (`EXT-X-MEDIA:TYPE=AUDIO`), AVPlayer stops downloading video segments
/// and only fetches audio segments.
///
/// **Strategy 2 — preferredPeakBitRate** (fallback):
/// Sets the peak bitrate to 1 bps, which effectively excludes all video variants
/// (typically 500kbps+) and only allows audio-quality streams through.
/// Handles cases where the media selection group is not yet available.
///
/// When re-enabling:
/// - Restores the default video rendition via AVMediaSelectionGroup
/// - Clears the bitrate restriction (0 = no limit)
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
        print("[VideoPlayer] No current player item for video track disable")
        result(nil)
        return
    }

    if disabled {
        // Strategy 1: Deselect the visual media selection group (demuxed HLS)
        if let asset = playerItem.asset as? AVURLAsset,
           let videoGroup = asset.mediaSelectionGroup(
               forMediaCharacteristic: .visual
           ) {
            playerItem.select(nil, in: videoGroup)
            print("[VideoPlayer] Video track disabled via AVMediaSelectionGroup")
        }

        // Strategy 2: Restrict bitrate to audio-only threshold (fallback)
        playerItem.preferredPeakBitRate = 1.0
        print("[VideoPlayer] preferredPeakBitRate set to 1.0 (audio-only)")
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
            print("[VideoPlayer] Video track re-enabled via AVMediaSelectionGroup")
        }

        // Clear bitrate restriction (0 = no limit)
        playerItem.preferredPeakBitRate = 0
        print("[VideoPlayer] preferredPeakBitRate cleared (no limit)")
    }

    result(nil)
}
```

### 5.2 Where to Add in VideoPlayerView.swift

If the method call routing goes through `VideoPlayerView.swift` instead of `VideoPlayerMethodHandler.swift`, add the case in the appropriate `handleMethodCall` switch in `VideoPlayerView.swift`:

```swift
case "setVideoTrackDisabled":
    handleSetVideoTrackDisabled(call: call, result: result)
```

Check how other methods like `"setSubtitleTrack"` are routed and follow the same pattern.

### 5.3 Why No Other iOS Files Need Changes

| File | Why no change needed |
|------|---------------------|
| `SharedPlayerManager.swift` | Already sets `audiovisualBackgroundPlaybackPolicy = .continuesIfPossible` (iOS 15+). Background audio works. |
| `VideoPlayerNowPlayingHandler.swift` | Already manages `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`. Lock screen controls work. |
| `VideoPlayerObserver.swift` | No new events to observe. |
| `Info.plist` (main app) | Already declares `UIBackgroundModes: ["audio"]`. |

### 5.4 iOS Background Audio Flow (Already Working)

```
1. App goes to background
2. iOS checks UIBackgroundModes → "audio" is declared ✓
3. AVAudioSession category is .playback ✓
4. audiovisualBackgroundPlaybackPolicy = .continuesIfPossible ✓
5. AVPlayer continues playing audio
6. MPNowPlayingInfoCenter shows on lock screen ✓
7. MPRemoteCommandCenter handles play/pause/skip ✓
8. setVideoTrackDisabled(true) → AVPlayer stops fetching video segments
9. Only audio segments downloaded → bandwidth saved ✓
```

---

## 6. Flutter Package — MethodChannel Bridge

### 6.1 File: `lib/src/platform/video_player_method_channel.dart`

Add after the `setSubtitleTrack` method:

```dart
/// Disables or enables the video track in the native player.
///
/// When [disabled] is true, the native player stops downloading video segments
/// from HLS demuxed streams, saving bandwidth during background playback.
/// Audio continues uninterrupted.
///
/// When [disabled] is false, video segment downloads resume from the current position.
Future<void> setVideoTrackDisabled(bool disabled) async {
  try {
    await _methodChannel.invokeMethod<void>(
      'setVideoTrackDisabled',
      <String, Object>{
        'viewId': primaryPlatformViewId,
        'disabled': disabled,
      },
    );
  } catch (e) {
    debugPrint('Error calling setVideoTrackDisabled: $e');
  }
}
```

### 6.2 File: `lib/src/controllers/native_video_player_controller.dart`

Add after the `setSubtitleTrack` method:

```dart
/// Disables or enables the video track in the native player.
///
/// When [disabled] is true, only audio segments are downloaded from HLS
/// demuxed streams. This is designed for background audio-only playback
/// to save bandwidth.
///
/// Call with `true` when the app goes to background,
/// `false` when returning to foreground.
Future<void> setVideoTrackDisabled(bool disabled) async {
  await _methodChannel?.setVideoTrackDisabled(disabled);
}
```

---

## 7. Files Changed Summary

| File | Change | ~LOC |
|------|--------|------|
| `android/.../handlers/VideoPlayerMethodHandler.kt` | Add `handleSetVideoTrackDisabled` + switch case | 25 |
| `android/.../handlers/VideoPlayerNotificationHandler.kt` | Start foreground service in `setupMediaSession()` | 10 |
| `ios/Classes/Handlers/VideoPlayerMethodHandler.swift` | Add `handleSetVideoTrackDisabled` + switch case | 50 |
| `lib/src/platform/video_player_method_channel.dart` | Add `setVideoTrackDisabled` MethodChannel call | 12 |
| `lib/src/controllers/native_video_player_controller.dart` | Add `setVideoTrackDisabled` public method | 8 |

**Total: ~105 lines across 5 files**

---

## 8. Testing the Fork Changes

### 8.1 Local Testing with the Main App

Use `pubspec_overrides.yaml` in the main app to point to your local fork clone:

```yaml
# apps/insight_timer/pubspec_overrides.yaml (gitignored, don't commit)
dependency_overrides:
  better_native_video_player:
    path: /path/to/your/local/flutter-native-video-player
```

Then run `flutter pub get` and test changes immediately without pushing.

### 8.2 Verification Steps

**Android:**
1. Play an HLS video with demuxed audio tracks
2. Call `setVideoTrackDisabled(true)` via the Flutter controller
3. Verify in logcat: `"Video track disabled"` log appears
4. Use Android Studio Network Profiler or Charles Proxy: only audio segment requests visible
5. Call `setVideoTrackDisabled(false)` — verify video segments resume
6. Background the app — verify foreground notification appears and audio continues
7. Verify app is NOT killed after 1+ minutes in background

**iOS:**
1. Play an HLS video with demuxed audio tracks
2. Call `setVideoTrackDisabled(true)` via the Flutter controller
3. Verify in Xcode console: `"Video track disabled via AVMediaSelectionGroup"` log appears
4. Use Charles Proxy: only audio segment requests visible
5. Call `setVideoTrackDisabled(false)` — verify video segments resume
6. Background the app — verify Now Playing info on lock screen, audio continues
7. Verify Control Center shows correct artwork and controls

---

## 9. PR Checklist for the Fork

- [ ] Feature branch created from latest main
- [ ] Android: `handleSetVideoTrackDisabled` added to `VideoPlayerMethodHandler.kt`
- [ ] Android: Foreground service started in `VideoPlayerNotificationHandler.setupMediaSession()`
- [ ] iOS: `handleSetVideoTrackDisabled` added to `VideoPlayerMethodHandler.swift`
- [ ] Dart: `setVideoTrackDisabled` added to `video_player_method_channel.dart`
- [ ] Dart: `setVideoTrackDisabled` added to `native_video_player_controller.dart`
- [ ] Tested on Android physical device with HLS demuxed stream
- [ ] Tested on iOS physical device with HLS demuxed stream
- [ ] Verified foreground notification works on Android background
- [ ] Verified Now Playing / lock screen controls work on iOS background
- [ ] No regressions in existing video playback, PiP, AirPlay, subtitles
