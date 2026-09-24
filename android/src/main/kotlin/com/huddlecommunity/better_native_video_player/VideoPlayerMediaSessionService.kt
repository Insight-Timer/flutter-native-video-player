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
 * Foreground MediaSessionService for background audio playback.
 *
 * The ExoPlayer and MediaSession are created externally in
 * [com.huddlecommunity.better_native_video_player.handlers.VideoPlayerNotificationHandler]
 * and registered with this service via [setActiveSession] before a handler starts
 * foreground playback.
 *
 * Only one active session is tracked at a time. When a second handler requests
 * foreground playback, its session replaces the previous one (single-owner model).
 * The system notification is built by Media3's [DefaultMediaNotificationProvider];
 * it runs through [startForeground] and is therefore exempt from the
 * POST_NOTIFICATIONS runtime permission on Android 13+.
 */
@androidx.annotation.OptIn(UnstableApi::class)
class VideoPlayerMediaSessionService : MediaSessionService() {

    companion object {
        private const val TAG = "VideoPlayerMSS"
        private const val NOTIFICATION_ID = 1001
        internal const val CHANNEL_ID = "video_player_channel"
        private const val LEGACY_CHANNEL_ID = "video_player"

        private var activeSession: MediaSession? = null

        fun getActiveSession(): MediaSession? = activeSession

        /**
         * Registers the session that should drive the foreground notification.
         * If another handler's session is already active, it is replaced.
         */
        fun setActiveSession(session: MediaSession?) {
            activeSession = session
        }

        /**
         * Clears the active session only if it still matches [session]. A handler
         * must call this on release so a later handler's session is not wiped.
         */
        fun clearActiveSessionIfMatches(session: MediaSession) {
            if (activeSession === session) {
                activeSession = null
            }
        }
    }

    private var registeredSession: MediaSession? = null
    private var isForegroundStarted = false

    // ── lifecycle ────────────────────────────────────────────────────────────

    override fun onCreate() {
        super.onCreate()

        val provider = DefaultMediaNotificationProvider.Builder(this)
            .setChannelId(CHANNEL_ID)
            .setNotificationId(NOTIFICATION_ID)
            .build()
        provider.setSmallIcon(resolveNotificationIcon())
        setMediaNotificationProvider(provider)

        setListener(ServiceListener())
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? {
        return activeSession
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Satisfy Android's 5s startForeground() deadline with a placeholder;
        // Media3 will replace it via onUpdateNotification moments later.
        startForegroundIfNeeded()

        val session = activeSession
        if (session == null) {
            // Nothing to play — let the service die rather than sit foregrounded.
            stopSelf()
            return super.onStartCommand(intent, flags, startId)
        }

        // addSession can throw IllegalArgumentException if the same session is added twice
        // on some Media3 versions, so swap registered sessions only on change.
        if (session !== registeredSession) {
            registeredSession?.let { prev ->
                runCatching { removeSession(prev) }
                    .onFailure { Log.w(TAG, "removeSession failed: ${it.message}") }
            }
            runCatching { addSession(session) }
                .onFailure { Log.w(TAG, "addSession failed: ${it.message}") }
            registeredSession = session
        }

        return super.onStartCommand(intent, flags, startId)
    }

    override fun onUpdateNotification(session: MediaSession, startInForegroundRequired: Boolean) {
        super.onUpdateNotification(session, startInForegroundRequired)
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        val session = activeSession
        // Stop only when there is no session or no media loaded. Keep the service
        // alive while media is loaded — even when paused — so the user can
        // resume from the notification after swiping the task away.
        if (session == null || session.player.mediaItemCount == 0) {
            stopSelf()
        }
    }

    override fun onDestroy() {
        isForegroundStarted = false
        registeredSession = null
        clearListener()
        super.onDestroy()
    }

    // ── foreground promotion ────────────────────────────────────────────────

    private fun startForegroundIfNeeded() {
        if (isForegroundStarted) return

        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER).setPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(this, 0, launchIntent, PendingIntent.FLAG_IMMUTABLE)
        val notificationManagerCompat = NotificationManagerCompat.from(this)
        ensureNotificationChannel(notificationManagerCompat)

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(resolveNotificationIcon())
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
    }

    // ── notification channel ────────────────────────────────────────────────

    private fun ensureNotificationChannel(nmc: NotificationManagerCompat) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

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
