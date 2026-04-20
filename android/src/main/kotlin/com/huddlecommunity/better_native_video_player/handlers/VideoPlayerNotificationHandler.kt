package com.huddlecommunity.better_native_video_player.handlers

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSession.ConnectionResult
import com.huddlecommunity.better_native_video_player.VideoPlayerMediaSessionService

/**
 * Owns the per-controller [MediaSession] and coordinates foreground-service
 * lifecycle for audio-only / background playback. The system notification
 * itself is produced by Media3's DefaultMediaNotificationProvider inside the
 * service; this class only creates the session and toggles the service on/off.
 */
class VideoPlayerNotificationHandler(
    private val context: Context,
    private val player: ExoPlayer,
    private var eventHandler: VideoPlayerEventHandler,
    private val disableMediaSession: Boolean = false
) {
    companion object {
        private var sessionCounter = 0
    }

    private var mediaSession: MediaSession? = null

    // Current metadata (wrappedPlayer reads these live, no session restart needed)
    private var currentTitle: String = "Video"
    private var currentSubtitle: String = ""
    private var showSkipControls: Boolean = true
    private var showSystemPreviousTrackControl: Boolean = false
    private var showSystemNextTrackControl: Boolean = false

    // Tracks whether we've asked the service to host a foreground notification
    // for this handler. Acts as a state-transition guard against rapid
    // setVideoTrackDisabled toggles requesting duplicate startForegroundService calls.
    private var foregroundRequested: Boolean = false

    // Guards release() so both handleDispose and PlatformView.dispose can call it.
    private var isReleased: Boolean = false

    /**
     * Wraps the ExoPlayer so that seekBack/seekForward can be intercepted when track-navigation
     * buttons are active. The system notification always calls seekBack()/seekForward() on the
     * player regardless of custom session commands, so interception must happen here.
     */
    private val wrappedPlayer = object : ForwardingPlayer(player) {
        override fun getAvailableCommands(): Player.Commands {
            val builder = super.getAvailableCommands().buildUpon()
            if (showSystemPreviousTrackControl) {
                builder.add(Player.COMMAND_SEEK_TO_PREVIOUS)
                builder.add(Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM)
            } else {
                builder.remove(Player.COMMAND_SEEK_TO_PREVIOUS)
                builder.remove(Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM)
            }
            if (showSystemNextTrackControl) {
                builder.add(Player.COMMAND_SEEK_TO_NEXT)
                builder.add(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)
            } else {
                builder.remove(Player.COMMAND_SEEK_TO_NEXT)
                builder.remove(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)
            }
            return builder.build()
        }

        override fun seekBack() {
            if (showSystemPreviousTrackControl) {
                eventHandler.sendEvent("previousTrack")
            } else {
                super.seekBack()
            }
        }

        override fun seekForward() {
            if (showSystemNextTrackControl) {
                eventHandler.sendEvent("nextTrack")
            } else {
                super.seekForward()
            }
        }

        // The system notification uses COMMAND_SEEK_TO_PREVIOUS / COMMAND_SEEK_TO_NEXT
        // (not COMMAND_SEEK_BACK / COMMAND_SEEK_FORWARD) for the ⏮ / ⏭ buttons.
        // On a single-item ExoPlayer playlist these would seek to position 0 / end of track,
        // so we must intercept them here as well.
        override fun seekToPrevious() {
            if (showSystemPreviousTrackControl) {
                eventHandler.sendEvent("previousTrack")
            } else {
                super.seekToPrevious()
            }
        }

        override fun seekToPreviousMediaItem() {
            if (showSystemPreviousTrackControl) {
                eventHandler.sendEvent("previousTrack")
            } else {
                super.seekToPreviousMediaItem()
            }
        }

        override fun seekToNext() {
            if (showSystemNextTrackControl) {
                eventHandler.sendEvent("nextTrack")
            } else {
                super.seekToNext()
            }
        }

        override fun seekToNextMediaItem() {
            if (showSystemNextTrackControl) {
                eventHandler.sendEvent("nextTrack")
            } else {
                super.seekToNextMediaItem()
            }
        }
    }

    private val mediaSessionCallback = object : MediaSession.Callback {
        override fun onConnect(
            session: MediaSession,
            controller: MediaSession.ControllerInfo,
        ): ConnectionResult {
            val base = super.onConnect(session, controller)
            if (!showSkipControls) {
                val playerCommands = base.availablePlayerCommands.buildUpon()
                    .remove(Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM)
                    .remove(Player.COMMAND_SEEK_BACK)
                    .remove(Player.COMMAND_SEEK_FORWARD)
                    .remove(Player.COMMAND_SEEK_TO_DEFAULT_POSITION)
                    .remove(Player.COMMAND_SEEK_TO_MEDIA_ITEM)
                    .remove(Player.COMMAND_SEEK_TO_PREVIOUS)
                    .remove(Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM)
                    .remove(Player.COMMAND_SEEK_TO_NEXT)
                    .remove(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)
                    .build()
                return ConnectionResult.accept(base.availableSessionCommands, playerCommands)
            }
            return base
        }
    }

    private val playerListener = object : Player.Listener {
        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
            if (playWhenReady) {
                eventHandler.sendEvent("play")
            } else {
                eventHandler.sendEvent("pause")
            }
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            when (playbackState) {
                Player.STATE_ENDED, Player.STATE_IDLE -> {
                    // Stop the foreground service when playback ends; Media3 handles
                    // regular notification updates in all other states.
                    stopForegroundPlayback()
                }
                else -> { /* no-op */ }
            }
        }
    }

    /**
     * Updates track navigation flags early (called from handleLoad before setMediaSource).
     * This ensures getAvailableCommands() returns the correct result when ExoPlayer fires
     * onAvailableCommandsChanged during media source preparation, so the system notification
     * shows ⏮/⏭ without requiring a session recreation.
     */
    fun updateTrackNavFlags(mediaInfo: Map<String, Any>?) {
        if (disableMediaSession) {
            return
        }
        val newShowPrev = (mediaInfo?.get("showSystemPreviousTrackControl") as? Boolean) ?: false
        val newShowNext = (mediaInfo?.get("showSystemNextTrackControl") as? Boolean) ?: false
        showSystemPreviousTrackControl = newShowPrev
        showSystemNextTrackControl = newShowNext
    }

    /**
     * Updates the event handler (needed when shared NotificationHandler is reused by new VideoPlayerView)
     */
    fun updateEventHandler(newEventHandler: VideoPlayerEventHandler) {
        eventHandler = newEventHandler
    }

    /**
     * Updates the player's current MediaItem metadata (title, artist, album, artwork URI).
     * Media3's DefaultMediaNotificationProvider reads these values to build the notification.
     */
    private fun updatePlayerMediaItemMetadata(mediaInfo: Map<String, Any>?) {
        if (mediaInfo == null) return

        val currentItem = player.currentMediaItem ?: return

        val metadataBuilder = MediaMetadata.Builder()
        (mediaInfo["title"] as? String)?.let { metadataBuilder.setTitle(it) }
        (mediaInfo["subtitle"] as? String)?.let { metadataBuilder.setArtist(it) }
        (mediaInfo["album"] as? String)?.let { metadataBuilder.setAlbumTitle(it) }
        (mediaInfo["artworkUrl"] as? String)?.let { artworkUrl ->
            runCatching { Uri.parse(artworkUrl) }
                .onSuccess { metadataBuilder.setArtworkUri(it) }
        }

        val updatedItem = currentItem.buildUpon()
            .setMediaMetadata(metadataBuilder.build())
            .build()

        val wasPlaying = player.isPlaying
        val position = player.currentPosition
        player.replaceMediaItem(player.currentMediaItemIndex, updatedItem)
        player.seekTo(position)
        if (wasPlaying) player.play()
    }

    /**
     * Sets up MediaSession with metadata (title, subtitle, artwork).
     * Similar to iOS MPNowPlayingInfoCenter — provides lock screen controls and system
     * media notification. The foreground service is NOT started here; call
     * [startForegroundPlayback] when switching to audio-only or background mode.
     */
    fun setupMediaSession(mediaInfo: Map<String, Any>?) {
        if (disableMediaSession) {
            return
        }
        val newTitle = (mediaInfo?.get("title") as? String) ?: "Video"
        val newSubtitle = (mediaInfo?.get("subtitle") as? String) ?: ""
        val newShowSkipControls = (mediaInfo?.get("showSkipControls") as? Boolean) ?: true
        val newShowSystemPreviousTrackControl = (mediaInfo?.get("showSystemPreviousTrackControl") as? Boolean) ?: false
        val newShowSystemNextTrackControl = (mediaInfo?.get("showSystemNextTrackControl") as? Boolean) ?: false

        val mediaInfoChanged = (newTitle != currentTitle || newSubtitle != currentSubtitle)
        val seekPermissionChanged = newShowSkipControls != showSkipControls

        currentTitle = newTitle
        currentSubtitle = newSubtitle
        showSkipControls = newShowSkipControls
        showSystemPreviousTrackControl = newShowSystemPreviousTrackControl
        showSystemNextTrackControl = newShowSystemNextTrackControl

        // Recreate MediaSession when seek permissions change so connected system controllers
        // receive the new command set via onConnect.
        if (seekPermissionChanged && mediaSession != null) {
            mediaSession?.let { VideoPlayerMediaSessionService.clearActiveSessionIfMatches(it) }
            mediaSession?.release()
            mediaSession = null
            player.removeListener(playerListener)
        }

        if (mediaSession != null) {
            if (mediaInfoChanged) {
                updatePlayerMediaItemMetadata(mediaInfo)
            }
            return
        }

        // Create pending intent to launch app when notification is clicked
        val packageManager = context.packageManager
        val intent = packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        } ?: Intent()
        val pendingIntent = PendingIntent.getActivity(
            context,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val sessionId = "huddle_video_player_${++sessionCounter}"
        mediaSession = MediaSession.Builder(context, wrappedPlayer)
            .setId(sessionId)
            .setSessionActivity(pendingIntent)
            .setCallback(mediaSessionCallback)
            .build()

        player.removeListener(playerListener)
        player.addListener(playerListener)

        mediaInfo?.let { updatePlayerMediaItemMetadata(it) }
    }

    /**
     * Starts the foreground service with media notification for audio-only / background
     * playback. Idempotent: repeated calls while already active are no-ops.
     *
     * Only one handler at a time can drive the foreground notification. If another
     * handler is active, calling this replaces it — by design, because the feature's
     * contract is "audio-only playback in the background" with a single visible player.
     */
    fun startForegroundPlayback() {
        if (disableMediaSession) {
            return
        }
        if (foregroundRequested) return
        val session = mediaSession ?: return

        // Publish our session to the service BEFORE starting it so onStartCommand
        // always finds a valid session to register — even if another handler's
        // release() ran concurrently and cleared theirs.
        VideoPlayerMediaSessionService.setActiveSession(session)

        val serviceIntent = Intent(context, VideoPlayerMediaSessionService::class.java)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
            foregroundRequested = true
        } catch (e: Exception) {
            // On Android 12+ background-initiated foreground starts can be blocked
            // (ForegroundServiceStartNotAllowedException). Revert the active-session
            // pointer so we don't leave a dangling reference.
            mediaSession?.let { VideoPlayerMediaSessionService.clearActiveSessionIfMatches(it) }
        }
    }

    /**
     * Stops the foreground service and removes the notification.
     * Idempotent: safe to call repeatedly.
     */
    fun stopForegroundPlayback() {
        if (!foregroundRequested) return
        foregroundRequested = false

        mediaSession?.let { VideoPlayerMediaSessionService.clearActiveSessionIfMatches(it) }

        try {
            val serviceIntent = Intent(context, VideoPlayerMediaSessionService::class.java)
            context.stopService(serviceIntent)
        } catch (_: Exception) { }
    }

    /**
     * Releases MediaSession and tears down the foreground service if we own it.
     * Safe to call multiple times.
     */
    fun release() {
        if (isReleased) return
        isReleased = true

        player.removeListener(playerListener)

        stopForegroundPlayback()
        mediaSession?.let { VideoPlayerMediaSessionService.clearActiveSessionIfMatches(it) }
        mediaSession?.release()
        mediaSession = null

        currentTitle = "Video"
        currentSubtitle = ""
    }
}
