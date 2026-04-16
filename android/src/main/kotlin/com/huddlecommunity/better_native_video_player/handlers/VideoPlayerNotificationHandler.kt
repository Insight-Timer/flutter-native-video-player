package com.huddlecommunity.better_native_video_player.handlers

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.support.v4.media.session.MediaSessionCompat
import androidx.core.app.NotificationCompat
import androidx.media.app.NotificationCompat as MediaNotificationCompat
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSession.ConnectionResult
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import com.huddlecommunity.better_native_video_player.VideoPlayerMediaSessionService
import java.net.URL

/**
 * Handles MediaSession and notification controls for lock screen and notification area
 * Equivalent to iOS VideoPlayerNowPlayingHandler
 */
class VideoPlayerNotificationHandler(
    private val context: Context,
    private val player: ExoPlayer,
    private var eventHandler: VideoPlayerEventHandler
) {
    companion object {
        private const val NOTIFICATION_ID = 1001
        private const val CHANNEL_ID = "video_player_channel"
        private var sessionCounter = 0
    }

    private var mediaSession: MediaSession? = null
    private val handler = Handler(Looper.getMainLooper())
    private var positionUpdateRunnable: Runnable? = null
    private var pendingStopWhenReadyListener: Player.Listener? = null
    private var pendingStopWhenReadyTimeout: Runnable? = null
    private val notificationManager: NotificationManager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private var currentArtwork: Bitmap? = null
    private var currentArtworkUrl: String? = null // Track which artwork we're currently loading

    // Store current metadata separately to avoid reading stale data from player
    private var currentTitle: String = "Video"
    private var currentSubtitle: String = ""
    private var showSkipControls: Boolean = true
    private var showSystemPreviousTrackControl: Boolean = false
    private var showSystemNextTrackControl: Boolean = false

    /**
     * Wraps the ExoPlayer so that seekBack/seekForward can be intercepted when track-navigation
     * buttons are active. The system notification always calls seekBack()/seekForward() on the
     * player regardless of custom session commands, so interception must happen here.
     */
    private val wrappedPlayer = object : ForwardingPlayer(player) {
        /**
         * Dynamically include/exclude the seek-to-previous and seek-to-next player commands based
         * on the track navigation flags. ExoPlayer never adds these commands for a single-item
         * playlist, so the system notification would never show ⏮/⏭ without this override.
         * The MediaSession calls getAvailableCommands() when pushing updates to controllers, so
         * updating the flags before setMediaSource() fires onAvailableCommandsChanged is enough
         * to make the buttons appear/disappear without recreating the session.
         */
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

    init {
        createNotificationChannel()
    }

    private val playerListener = object : Player.Listener {
        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
            if (playWhenReady) {
                eventHandler.sendEvent("play")
            } else {
                eventHandler.sendEvent("pause")
            }
            // Media3's MediaSessionService handles notification updates automatically.
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            when (playbackState) {
                Player.STATE_ENDED, Player.STATE_IDLE -> {
                    // Stop the foreground service when playback ends
                    try {
                        val serviceIntent = Intent(context, VideoPlayerMediaSessionService::class.java)
                        context.stopService(serviceIntent)
                    } catch (_: Exception) { }
                }
                else -> { /* Media3 handles notification updates */ }
            }
        }
    }

    /**
     * Creates notification channel for Android O+
     */
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Video Player",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Media playback controls"
                setShowBadge(false)
            }
            notificationManager.createNotificationChannel(channel)
        }
    }

    /**
     * Updates track navigation flags early (called from handleLoad before setMediaSource).
     * This ensures getAvailableCommands() returns the correct result when ExoPlayer fires
     * onAvailableCommandsChanged during media source preparation, so the system notification
     * shows ⏮/⏭ without requiring a session recreation.
     */
    fun updateTrackNavFlags(mediaInfo: Map<String, Any>?) {
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
     * Updates the player's current MediaItem metadata (title, artist, album)
     * This is essential for MediaSession to display correct info in notification
     */
    private fun updatePlayerMediaItemMetadata(mediaInfo: Map<String, Any>?) {
        if (mediaInfo == null) return

        val currentItem = player.currentMediaItem ?: return

        // Build new metadata from mediaInfo
        val metadataBuilder = MediaMetadata.Builder()
        (mediaInfo["title"] as? String)?.let { metadataBuilder.setTitle(it) }
        (mediaInfo["subtitle"] as? String)?.let { metadataBuilder.setArtist(it) }
        (mediaInfo["album"] as? String)?.let { metadataBuilder.setAlbumTitle(it) }
        (mediaInfo["artworkUrl"] as? String)?.let { artworkUrl ->
            runCatching { Uri.parse(artworkUrl) }
                .onSuccess { metadataBuilder.setArtworkUri(it) }
        }

        // Create updated MediaItem with new metadata
        val updatedItem = currentItem.buildUpon()
            .setMediaMetadata(metadataBuilder.build())
            .build()

        // Replace the MediaItem without interrupting playback
        val wasPlaying = player.isPlaying
        val position = player.currentPosition
        player.replaceMediaItem(player.currentMediaItemIndex, updatedItem)
        player.seekTo(position)
        if (wasPlaying) player.play()
    }

    /**
     * Sets up MediaSession with metadata (title, subtitle, artwork)
     * Similar to iOS MPNowPlayingInfoCenter - shows on lock screen when playing
     * MediaSession automatically provides lock screen controls and system media notification
     */
    fun setupMediaSession(mediaInfo: Map<String, Any>?) {
        // Extract metadata from the provided info
        val newTitle = (mediaInfo?.get("title") as? String) ?: "Video"
        val newSubtitle = (mediaInfo?.get("subtitle") as? String) ?: ""
        val newShowSkipControls = (mediaInfo?.get("showSkipControls") as? Boolean) ?: true
        val newShowSystemPreviousTrackControl = (mediaInfo?.get("showSystemPreviousTrackControl") as? Boolean) ?: false
        val newShowSystemNextTrackControl = (mediaInfo?.get("showSystemNextTrackControl") as? Boolean) ?: false

        // Check if media info has actually changed to avoid unnecessary updates
        val mediaInfoChanged = (newTitle != currentTitle || newSubtitle != currentSubtitle)
        val seekPermissionChanged = newShowSkipControls != showSkipControls

        // Store the new metadata (wrappedPlayer reads these fields live, so no session restart needed)
        currentTitle = newTitle
        currentSubtitle = newSubtitle
        showSkipControls = newShowSkipControls
        showSystemPreviousTrackControl = newShowSystemPreviousTrackControl
        showSystemNextTrackControl = newShowSystemNextTrackControl

        // Recreate MediaSession when seek permissions change so connected system controllers
        // receive the new command set via onConnect.
        if (seekPermissionChanged && mediaSession != null) {
            mediaSession?.release()
            mediaSession = null
            player.removeListener(playerListener)
        }

        // If MediaSession already exists, only update if media info changed
        if (mediaSession != null) {
            // Only update MediaItem if the info actually changed to avoid playback interruptions
            if (mediaInfoChanged) {
                currentArtwork = null // Clear old artwork
                currentArtworkUrl = null // Clear artwork URL to ignore pending loads

                // Update the player's MediaItem with the new metadata
                updatePlayerMediaItemMetadata(mediaInfo)

                // Load new artwork asynchronously
                mediaInfo?.let { info ->
                    updateMediaMetadata(info)
                }

                // Update notification with new info
                handler.post {
                    if (player.playWhenReady) {
                        updateNotification()
                    }
                }
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

        // Create MediaSession with unique session ID and activity (opens app when notification is tapped)
        val sessionId = "huddle_video_player_${++sessionCounter}"
        mediaSession = MediaSession.Builder(context, wrappedPlayer)
            .setId(sessionId)
            .setSessionActivity(pendingIntent)
            .setCallback(mediaSessionCallback)
            .build()

        // Add listener to track play/pause events
        player.removeListener(playerListener)
        player.addListener(playerListener)

        // Set metadata on the player's MediaItem first (for MediaSession to use)
        mediaInfo?.let { info ->
            updatePlayerMediaItemMetadata(info)
        }

        // Load artwork asynchronously if provided
        mediaInfo?.let { info ->
            updateMediaMetadata(info)
        }

        // Store the session so it's available when the foreground service is started later.
        // The service is NOT started here — it's started only when:
        // 1. setVideoTrackDisabled(true) is called (audio mode or background)
        // 2. Via startForegroundPlayback() below
        VideoPlayerMediaSessionService.setMediaSession(mediaSession)

        // Start periodic position updates
        startPositionUpdates()
    }

    /**
     * Starts the foreground service with media notification.
     * Call this ONLY when switching to audio-only playback (background or manual audio mode).
     * NOT when video is playing in the foreground.
     */
    fun startForegroundPlayback() {
        if (mediaSession == null) return

        // Cancel any pending deferred stop — user switched back to audio mode
        // before the previous stopWhenReady completed.
        pendingStopWhenReadyListener?.let { player.removeListener(it) }
        pendingStopWhenReadyTimeout?.let { handler.removeCallbacks(it) }
        pendingStopWhenReadyListener = null
        pendingStopWhenReadyTimeout = null

        val serviceIntent = Intent(context, VideoPlayerMediaSessionService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(serviceIntent)
        } else {
            context.startService(serviceIntent)
        }
    }

    /**
     * Stops the foreground service and removes the notification.
     * Call when switching back to video mode from audio mode.
     */
    fun stopForegroundPlayback() {
        pendingStopWhenReadyListener?.let { player.removeListener(it) }
        pendingStopWhenReadyTimeout?.let { handler.removeCallbacks(it) }
        pendingStopWhenReadyListener = null
        pendingStopWhenReadyTimeout = null

        try {
            val serviceIntent = Intent(context, VideoPlayerMediaSessionService::class.java)
            context.stopService(serviceIntent)
        } catch (_: Exception) { }
    }

    /**
     * Stops the foreground service only after playback returns to STATE_READY.
     * This keeps process priority elevated while video is being re-enabled.
     */
    fun stopForegroundPlaybackWhenReady() {
        if (player.playbackState == Player.STATE_READY && player.playWhenReady) {
            stopForegroundPlayback()
            return
        }

        pendingStopWhenReadyListener?.let { player.removeListener(it) }
        pendingStopWhenReadyTimeout?.let { handler.removeCallbacks(it) }
        pendingStopWhenReadyListener = null
        pendingStopWhenReadyTimeout = null

        val readyListener = object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                if (playbackState == Player.STATE_READY) {
                    pendingStopWhenReadyListener?.let { player.removeListener(it) }
                    pendingStopWhenReadyTimeout?.let { handler.removeCallbacks(it) }
                    pendingStopWhenReadyListener = null
                    pendingStopWhenReadyTimeout = null
                    stopForegroundPlayback()
                }
            }
        }

        val timeoutRunnable = Runnable {
            pendingStopWhenReadyListener?.let { player.removeListener(it) }
            pendingStopWhenReadyListener = null
            pendingStopWhenReadyTimeout = null
            stopForegroundPlayback()
        }

        pendingStopWhenReadyListener = readyListener
        pendingStopWhenReadyTimeout = timeoutRunnable
        player.addListener(readyListener)
        handler.postDelayed(timeoutRunnable, 5000)
    }

    private fun showNotification() {
        // No-op: Media3 handles notification via the foreground service.
    }

    private fun updateNotification() {
        // No-op: Media3 handles notification updates.
    }

    private fun hideNotification() {
        stopForegroundPlayback()
    }

    /**
     * Builds the media notification
     */
    private fun buildNotification(): Notification {
        val session = mediaSession ?: throw IllegalStateException("MediaSession not initialized")

        // Read metadata from the player's current MediaItem (source of truth for MediaSession)
        // This ensures the notification always shows what the MediaSession is actually playing
        val mediaMetadata = player.currentMediaItem?.mediaMetadata
        val title = mediaMetadata?.title?.toString() ?: currentTitle
        val artist = mediaMetadata?.artist?.toString() ?: currentSubtitle

        // Create pending intent for the notification
        val packageManager = context.packageManager
        val intent = packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        } ?: Intent()
        val contentIntent = PendingIntent.getActivity(
            context,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        // Use a system drawable for the small icon — adaptive/mipmap launcher icons
        // are silently suppressed by Android's notification system.
        val iconResId = android.R.drawable.ic_media_play

        // Convert Media3 SessionToken to MediaSessionCompat.Token for notification
        // Media3 1.4.0+ requires us to extract the token differently
        val token = try {
            // Use reflection to access the session compat token
            val method = session.javaClass.getMethod("getSessionCompatToken")
            method.invoke(session) as? MediaSessionCompat.Token
        } catch (_: Exception) {
            null
        }

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(artist)
            .setSmallIcon(iconResId)
            .setLargeIcon(currentArtwork)
            .setContentIntent(contentIntent)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)

        // Only set media session token if we successfully obtained it
        if (token != null) {
            builder.setStyle(
                MediaNotificationCompat.MediaStyle()
                    .setMediaSession(token)
            )
        }

        return builder.build()
    }

    /**
     * Updates media metadata (title, artist, artwork)
     * This is called after the MediaItem is already set, so we just load artwork
     * The base metadata was already set when creating the MediaItem
     */
    fun updateMediaMetadata(mediaInfo: Map<String, Any>) {
        // Load artwork asynchronously if present and update the notification
        val artworkUrl = mediaInfo["artworkUrl"] as? String
        if (artworkUrl != null) {
            currentArtworkUrl = artworkUrl // Track the current artwork URL
            loadArtwork(artworkUrl) { bitmap ->
                // Only use this artwork if it's still the current one (prevent race conditions)
                if (artworkUrl != currentArtworkUrl) return@loadArtwork

                bitmap?.let {
                    currentArtwork = it

                    // Update notification directly with the new artwork
                    // DO NOT call replaceMediaItem here as it can interrupt playback
                    // The notification will use currentArtwork automatically
                    if (player.playWhenReady) {
                        handler.post { updateNotification() }
                    }
                }
            }
        }

    }

    /**
     * Loads artwork from URL
     */
    private fun loadArtwork(url: String, callback: (Bitmap?) -> Unit) {
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val connection = URL(url).openConnection()
                val bitmap = BitmapFactory.decodeStream(connection.getInputStream())
                withContext(Dispatchers.Main) {
                    callback(bitmap)
                }
            } catch (_: Exception) {
                withContext(Dispatchers.Main) {
                    callback(null)
                }
            }
        }
    }

    /**
     * Converts Bitmap to ByteArray
     */
    private fun bitmapToByteArray(bitmap: Bitmap): ByteArray {
        val stream = java.io.ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
        return stream.toByteArray()
    }

    /**
     * Starts periodic position updates (every second)
     */
    private fun startPositionUpdates() {
        positionUpdateRunnable = object : Runnable {
            override fun run() {
                // Position is automatically updated by ExoPlayer/MediaSession
                handler.postDelayed(this, 1000)
            }
        }
        handler.post(positionUpdateRunnable!!)
    }

    /**
     * Stops periodic position updates
     */
    private fun stopPositionUpdates() {
        positionUpdateRunnable?.let { handler.removeCallbacks(it) }
        positionUpdateRunnable = null
    }

    /**
     * Releases MediaSession and hides notification
     */
    fun release() {
        stopPositionUpdates()
        player.removeListener(playerListener)

        stopForegroundPlayback()
        VideoPlayerMediaSessionService.setMediaSession(null)
        mediaSession?.release()
        mediaSession = null
        currentArtwork = null
        currentArtworkUrl = null
        currentTitle = "Video"
        currentSubtitle = ""
    }
}
