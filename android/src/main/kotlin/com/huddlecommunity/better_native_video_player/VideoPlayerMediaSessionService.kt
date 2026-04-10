package com.huddlecommunity.better_native_video_player

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

/**
 * Foreground MediaSessionService for background video/audio playback.
 *
 * Modelled after InsightMediaSessionService in the insight_timer_player package.
 * Key difference: the ExoPlayer and MediaSession are created EXTERNALLY in
 * VideoPlayerNotificationHandler and handed in via the static setMediaSession().
 *
 * Media3's DefaultMediaNotificationProvider (configured via a CustomMediaNotificationProvider
 * subclass) builds the notification through startForeground(), which is exempt from
 * the POST_NOTIFICATIONS runtime permission on Android 13+.
 */
@androidx.annotation.OptIn(UnstableApi::class)
class VideoPlayerMediaSessionService : MediaSessionService() {

    companion object {
        private const val TAG = "VideoPlayerMSS"
        private const val NOTIFICATION_ID = 1001
        private const val CHANNEL_ID = "video_player_channel"
        private const val LEGACY_CHANNEL_ID = "video_player"

        private var mediaSession: MediaSession? = null
        private var isForegroundStarted = false

        fun getMediaSession(): MediaSession? = mediaSession

        /**
         * Called by VideoPlayerNotificationHandler after it creates the MediaSession.
         */
        fun setMediaSession(session: MediaSession?) {
            Log.d(TAG, "===== setMediaSession: session=${session != null}, player=${session?.player != null}")
            mediaSession = session
        }
    }

    // ── lifecycle ────────────────────────────────────────────────────────────

    override fun onCreate() {
        super.onCreate()

        // Wire up the notification provider exactly like InsightMediaSessionService.
        // This subclass controls which buttons appear and in what order.
        val provider = DefaultMediaNotificationProvider.Builder(this)
            .setChannelId(CHANNEL_ID)
            .setNotificationId(NOTIFICATION_ID)
            .build()
        // Use the app's dedicated notification icon (monochrome drawable).
        // android.R.drawable.ic_media_play is a safe fallback if ic_notification doesn't exist.
        val iconRes = resolveNotificationIcon()
        provider.setSmallIcon(iconRes)
        setMediaNotificationProvider(provider)

        setListener(ServiceListener())
        Log.d(TAG, "===== SERVICE onCreate – provider & listener set")
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? {
        Log.d(TAG, "===== SERVICE onGetSession, session=${mediaSession != null}")
        return mediaSession
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "===== SERVICE onStartCommand, session=${mediaSession != null}")

        // Immediately satisfy Android's 5-second startForeground() deadline with a placeholder.
        startForegroundIfNeeded()

        // Explicitly register the external MediaSession with the service.
        // MediaSessionService's notification pipeline only activates when it knows about a session.
        // onGetSession() is never called because no MediaController binds via startForegroundService().
        // addSession() is the Media3 API for registering externally-created sessions —
        // it triggers the internal connection + notification pipeline.
        val session = mediaSession
        if (session != null) {
            Log.d(TAG, "===== SERVICE calling addSession()")
            addSession(session)
        }

        return super.onStartCommand(intent, flags, startId)
    }

    override fun onUpdateNotification(session: MediaSession, startInForegroundRequired: Boolean) {
        // Let Media3 + CustomMediaNotificationProvider handle everything.
        super.onUpdateNotification(session, startInForegroundRequired)
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.d(TAG, "===== SERVICE onTaskRemoved")
        val session = mediaSession
        if (session == null || !session.player.playWhenReady || session.player.mediaItemCount == 0) {
            stopSelf()
        }
    }

    override fun onDestroy() {
        Log.d(TAG, "===== SERVICE onDestroy")
        isForegroundStarted = false
        clearListener()
        super.onDestroy()
    }

    // ── foreground promotion ────────────────────────────────────────────────

    /**
     * Posts a minimal foreground notification so the service satisfies Android's
     * startForeground() contract. Media3 will replace it with the real media
     * notification moments later via [onUpdateNotification].
     *
     * Copied from InsightMediaSessionService.startForegroundIfNeeded().
     */
    private fun startForegroundIfNeeded() {
        if (isForegroundStarted) return

        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER).setPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(this, 0, launchIntent, PendingIntent.FLAG_IMMUTABLE)
        val notificationManagerCompat = NotificationManagerCompat.from(this)
        ensureNotificationChannel(notificationManagerCompat)

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(resolveNotificationIcon())
            .setContentTitle("Playing")
            .setContentIntent(pendingIntent)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setDefaults(0)
            .setSound(null)
            .setVibrate(longArrayOf(0L))
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        isForegroundStarted = true
        Log.d(TAG, "===== SERVICE startForeground done (MEDIA_PLAYBACK)")
    }

    // ── notification channel ────────────────────────────────────────────────

    private fun ensureNotificationChannel(nmc: NotificationManagerCompat) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        // Remove legacy channel if it exists
        if (nmc.getNotificationChannel(LEGACY_CHANNEL_ID) != null) {
            nmc.deleteNotificationChannel(LEGACY_CHANNEL_ID)
        }
        if (nmc.getNotificationChannel(CHANNEL_ID) != null) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            "Video Playback",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            setSound(null, null)
            enableVibration(false)
            vibrationPattern = longArrayOf(0L)
            setShowBadge(false)
        }
        nmc.createNotificationChannel(channel)
    }

    // ── icon helper ─────────────────────────────────────────────────────────

    private fun resolveNotificationIcon(): Int {
        // Try the app's dedicated notification icon first (same as audio player).
        val resId = resources.getIdentifier("ic_notification", "drawable", packageName)
        return if (resId != 0) resId else android.R.drawable.ic_media_play
    }

    // ── Media3 listener for Android 12+ background-start restriction ────────

    private inner class ServiceListener : Listener {
        override fun onForegroundServiceStartNotAllowedException() {
            Log.w(TAG, "Foreground service start not allowed (Android 12+ restriction)")
        }
    }

}
