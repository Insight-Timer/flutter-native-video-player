package com.huddlecommunity.better_native_video_player

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.media3.common.Player
import androidx.media3.session.CommandButton
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionResult
import com.google.common.collect.ImmutableList
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture

/**
 * MediaSessionService for native video player
 * Provides automatic media notification controls with play/pause buttons
 * Based on: https://developer.android.com/media/implement/surfaces/mobile
 *
 * IMPORTANT: MediaSessionService automatically creates and manages the notification
 * when there's an active MediaSession and the system calls onGetSession()
 * The notification appears automatically when media is playing
 */
class VideoPlayerMediaSessionService : MediaSessionService() {

    companion object {
        private const val TAG = "VideoPlayerMSS"
        private const val NOTIFICATION_ID = 1001
        private const val CHANNEL_ID = "video_player_channel"

        // The MediaSession is stored here so it can be accessed by the service
        private var mediaSession: MediaSession? = null

        /**
         * Gets the current media session
         */
        fun getMediaSession(): MediaSession? = mediaSession

        /**
         * Sets the media session (called by VideoPlayerNotificationHandler)
         * This must be called before starting the service
         */
        fun setMediaSession(session: MediaSession?) {
            Log.d(TAG, "MediaSession ${if (session != null) "set" else "cleared"}, hasPlayer=${session?.player != null}")
            mediaSession = session
        }
    }

    override fun onCreate() {
        super.onCreate()

        // Configure Media3's notification provider so it knows which channel and
        // notification ID to use when building the real media notification.
        // Without this, Media3 never replaces the placeholder posted in onStartCommand().
        val notificationProvider = DefaultMediaNotificationProvider.Builder(this)
            .setChannelId(CHANNEL_ID)
            .setNotificationId(NOTIFICATION_ID)
            .build()
        notificationProvider.setSmallIcon(applicationInfo.icon)
        setMediaNotificationProvider(notificationProvider)

        // Handle Android 12+ background start restrictions gracefully
        setListener(object : Listener {
            override fun onForegroundServiceStartNotAllowedException() {
                Log.w(TAG, "Foreground service start not allowed (Android 12+ background restriction)")
            }
        })

        Log.d(TAG, "VideoPlayerMediaSessionService onCreate, mediaSession=${mediaSession != null}")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "onStartCommand called, mediaSession=${mediaSession != null}, player=${mediaSession?.player != null}")

        // Immediately promote to foreground with a placeholder notification to satisfy
        // Android's 5-second startForeground() deadline. Media3's super.onStartCommand()
        // will replace this with the real media notification once it processes the session.
        startForegroundWithPlaceholder()

        // Now let Media3 do its work — it will replace the placeholder notification
        val result = super.onStartCommand(intent, flags, startId)

        // Log player state for debugging
        mediaSession?.player?.let { player ->
            Log.d(TAG, "Player state: playWhenReady=${player.playWhenReady}, playbackState=${player.playbackState}, mediaItemCount=${player.mediaItemCount}")
        }

        return result
    }

    /**
     * Posts a minimal foreground notification so the service satisfies Android's
     * startForeground() contract before Media3 builds the real media notification.
     */
    private fun startForegroundWithPlaceholder() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "Video Playback",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Controls for video playback"
                    setSound(null, null)
                }
                (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
                    .createNotificationChannel(channel)
            }

            // Build a launch intent so tapping the placeholder opens the app
            val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                ?: Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER).setPackage(packageName)
            val pendingIntent = PendingIntent.getActivity(
                this, 0, launchIntent, PendingIntent.FLAG_IMMUTABLE
            )

            val notification = NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle("Playing")
                .setSmallIcon(applicationInfo.icon)
                .setContentIntent(pendingIntent)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setOngoing(true)
                .setSilent(true)
                .build()

            startForeground(NOTIFICATION_ID, notification)
            Log.d(TAG, "Placeholder foreground notification posted")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start foreground: ${e.message}", e)
        }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? {
        Log.d(TAG, "onGetSession called for ${controllerInfo.packageName}, returning session=${mediaSession != null}")

        // Return the MediaSession - this triggers the notification to appear
        return mediaSession
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.d(TAG, "Task removed")
        val session = mediaSession
        if (session != null) {
            if (!session.player.playWhenReady || session.player.mediaItemCount == 0) {
                // Stop the service if not playing
                Log.d(TAG, "Stopping service - not playing")
                stopSelf()
            }
        } else {
            stopSelf()
        }
    }

    override fun onDestroy() {
        Log.d(TAG, "VideoPlayerMediaSessionService onDestroy")
        // Don't release the player or session here - they're managed by the notification handler
        super.onDestroy()
    }
}