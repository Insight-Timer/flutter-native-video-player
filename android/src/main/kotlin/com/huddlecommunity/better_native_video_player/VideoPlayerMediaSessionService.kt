package com.huddlecommunity.better_native_video_player

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

/**
 * MediaSessionService for native video player.
 *
 * The MediaSession is created externally by VideoPlayerNotificationHandler and passed in
 * via the static [setMediaSession] / [addSession] methods. This service owns the foreground
 * lifecycle and delegates notification rendering to Media3's DefaultMediaNotificationProvider.
 *
 * Foreground service flow:
 *   1. NotificationHandler calls setMediaSession(session) + startForegroundService()
 *   2. onStartCommand() immediately posts a placeholder notification to satisfy Android's
 *      5-second startForeground() deadline.
 *   3. super.onStartCommand() triggers Media3's notification pipeline which replaces the
 *      placeholder with a rich media notification (artwork, play/pause, skip controls).
 */
class VideoPlayerMediaSessionService : MediaSessionService() {

    companion object {
        private const val NOTIFICATION_ID = 1001
        private const val CHANNEL_ID = "video_player_channel"

        private var mediaSession: MediaSession? = null

        fun getMediaSession(): MediaSession? = mediaSession

        /**
         * Sets the media session (called by VideoPlayerNotificationHandler).
         * Must be called before starting the service.
         */
        fun setMediaSession(session: MediaSession?) {
            mediaSession = session
        }
    }

    override fun onCreate() {
        super.onCreate()

        val notificationProvider = DefaultMediaNotificationProvider.Builder(this)
            .setChannelId(CHANNEL_ID)
            .setNotificationId(NOTIFICATION_ID)
            .build()
        notificationProvider.setSmallIcon(resolveNotificationIcon())
        setMediaNotificationProvider(notificationProvider)

        setListener(object : Listener {
            override fun onForegroundServiceStartNotAllowedException() {
                // Android 12+ background start restriction — nothing to do
            }
        })
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundWithPlaceholder()
        mediaSession?.let { addSession(it) }
        return super.onStartCommand(intent, flags, startId)
    }

    /**
     * Posts a minimal foreground notification to satisfy Android's 5-second deadline.
     * Media3 replaces this with the real media notification shortly after.
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

            val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                ?: Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER).setPackage(packageName)
            val pendingIntent = PendingIntent.getActivity(
                this, 0, launchIntent, PendingIntent.FLAG_IMMUTABLE
            )

            val notification = NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle("Playing")
                .setSmallIcon(resolveNotificationIcon())
                .setContentIntent(pendingIntent)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setOngoing(true)
                .setSilent(true)
                .build()

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (_: Exception) { }
    }

    /**
     * Resolves the best available notification icon.
     * Prefers a dedicated ic_notification drawable, falls back to the app launcher icon.
     */
    private fun resolveNotificationIcon(): Int {
        val iconRes = resources.getIdentifier("ic_notification", "drawable", packageName)
        return if (iconRes != 0) iconRes else applicationInfo.icon
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? {
        return mediaSession
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        val session = mediaSession
        if (session != null) {
            if (!session.player.playWhenReady || session.player.mediaItemCount == 0) {
                stopSelf()
            }
        } else {
            stopSelf()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
    }
}
