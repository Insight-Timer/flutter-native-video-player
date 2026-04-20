package com.huddlecommunity.better_native_video_player.manager

import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.media3.common.C
import androidx.media3.common.AudioAttributes
import androidx.media3.exoplayer.ExoPlayer
import com.huddlecommunity.better_native_video_player.VideoPlayerMediaSessionService
import com.huddlecommunity.better_native_video_player.handlers.VideoPlayerNotificationHandler
import com.huddlecommunity.better_native_video_player.handlers.VideoPlayerEventHandler

/**
 * Manages shared ExoPlayer instances and NotificationHandlers across multiple platform views
 * Keeps players and notification handlers alive even when platform views are disposed
 * Note: Each platform view gets its own PlayerView, but they share the same ExoPlayer and NotificationHandler
 */
object SharedPlayerManager {
    private const val TAG = "SharedPlayerManager"
    private const val SEEK_INCREMENT_MS = 15_000L

    private val players = mutableMapOf<Int, ExoPlayer>()
    private val notificationHandlers = mutableMapOf<Int, VideoPlayerNotificationHandler>()

    // External ExoPlayer reference supplied by the host app. Accessed ONLY via
    // getExternalPlayer() — never returned silently from getOrCreatePlayer().
    // Intended use: a caller who explicitly wants the host-owned player (e.g.
    // fork VideoPlayerView constructed with useExternalPlayer=true) fetches
    // the reference here and attaches its rendering surface. Internal-player
    // callers are unaffected by this reference.
    //
    // Lifecycle: the OWNER of the external player is responsible for release().
    // SharedPlayerManager must never call release() on an external player.
    //
    // Thread-safety: reads of externalPlayer are volatile. All mutations AND
    // all listener-list operations go through externalPlayerLock so the
    // check-then-act in addExternalPlayerListener is atomic with respect to
    // setExternalPlayer's snapshot+clear.
    @Volatile
    private var externalPlayer: ExoPlayer? = null

    // Listeners registered by VideoPlayerViews that fell back to an internal
    // ExoPlayer because the external wasn't registered yet. When setExternalPlayer
    // is called with a non-null value, every listener is invoked synchronously
    // with the new external player so views can rebind their surfaces.
    //
    // Guarded by externalPlayerLock.
    private val externalPlayerListeners = mutableListOf<(ExoPlayer) -> Unit>()

    // Single lock guarding externalPlayer writes and all externalPlayerListeners
    // operations. Listener invocations happen OUTSIDE this lock to avoid
    // reentrant deadlocks (callbacks may call other SharedPlayerManager APIs).
    private val externalPlayerLock = Any()

    /**
     * Registers an externally-owned ExoPlayer. Subsequent calls to
     * [getExternalPlayer] return this instance. This method does NOT touch
     * the internally-managed [players] map — existing internal players keep
     * functioning independently.
     *
     * Pass null to detach.
     *
     * The caller retains ownership — SharedPlayerManager will never call
     * release() on this player.
     *
     * Thread-safe: may be called from any thread (typically the host app's
     * audio service thread). Registered listeners are invoked outside the
     * internal lock on the caller's thread.
     */
    fun setExternalPlayer(player: ExoPlayer?) {
        // Atomically update the reference and drain the listener list. Drain
        // only happens for non-null registrations (null = detach).
        val listenersToNotify: List<(ExoPlayer) -> Unit> = synchronized(externalPlayerLock) {
            externalPlayer = player
            if (player != null) {
                val snapshot = externalPlayerListeners.toList()
                externalPlayerListeners.clear()
                snapshot
            } else {
                emptyList()
            }
        }
        // Invoke listeners outside the lock. `player` is non-null here because
        // we only populated listenersToNotify in the non-null branch above.
        if (listenersToNotify.isNotEmpty() && player != null) {
            listenersToNotify.forEach { it(player) }
        }
    }

    /**
     * Returns the currently-registered external ExoPlayer, or null if none.
     * Use this to branch on external-player availability without going through
     * getOrCreatePlayer(), which has map-caching side effects.
     */
    fun getExternalPlayer(): ExoPlayer? {
        return externalPlayer
    }

    /**
     * Register a callback to be invoked when an external ExoPlayer is registered.
     * If an external player is already present, the callback fires IMMEDIATELY
     * on the caller's thread and is NOT added to the list. Otherwise the callback
     * is added and will be invoked from [setExternalPlayer] when a non-null
     * player arrives.
     *
     * Thread-safe: the check-then-add is performed atomically against
     * setExternalPlayer, so a listener cannot be lost to a race where the
     * player arrives between the check and the add.
     */
    fun addExternalPlayerListener(callback: (ExoPlayer) -> Unit) {
        val existing: ExoPlayer? = synchronized(externalPlayerLock) {
            val current = externalPlayer
            if (current == null) {
                externalPlayerListeners.add(callback)
            }
            current
        }
        // Invoke outside the lock so callbacks can't re-enter into a locked
        // section and deadlock.
        if (existing != null) {
            callback(existing)
        }
    }

    /**
     * Remove a previously registered listener. Safe to call even if the listener
     * has already fired (no-op in that case).
     */
    fun removeExternalPlayerListener(callback: (ExoPlayer) -> Unit) {
        synchronized(externalPlayerLock) {
            externalPlayerListeners.remove(callback)
        }
    }

    // Track active platform views for each controller
    // Map<ControllerId, Map<ViewId, SurfaceReconnectCallback>>
    private val activeViews = mutableMapOf<Int, MutableMap<Long, () -> Unit>>()

    // Store available qualities for each controller
    // This ensures qualities persist across view recreations
    private val qualitiesCache = mutableMapOf<Int, List<Map<String, Any>>>()

    /**
     * Gets or creates an INTERNAL player for the given controller ID.
     * Returns a Pair<ExoPlayer, Boolean> where the Boolean indicates if the
     * player already existed (true) or was newly created (false).
     *
     * This method NEVER returns the external player. Callers who want the
     * host-owned external ExoPlayer must call [getExternalPlayer] directly.
     */
    fun getOrCreatePlayer(context: Context, controllerId: Int): Pair<ExoPlayer, Boolean> {
        val alreadyExisted = players.containsKey(controllerId)
        val player = players.getOrPut(controllerId) {
            ExoPlayer.Builder(context)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(C.USAGE_MEDIA)
                        .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                        .build(),
                    true
                )
                .setSeekBackIncrementMs(SEEK_INCREMENT_MS)
                .setSeekForwardIncrementMs(SEEK_INCREMENT_MS)
                .build()
        }
        return Pair(player, alreadyExisted)
    }

    /**
     * Gets or creates a notification handler for the given controller ID
     */
    fun getOrCreateNotificationHandler(
        context: Context,
        controllerId: Int,
        player: ExoPlayer,
        eventHandler: VideoPlayerEventHandler,
        disableMediaSession: Boolean = false
    ): VideoPlayerNotificationHandler {
        // Existence check BEFORE getOrPut so we can log when a subsequent
        // caller requests a different disableMediaSession than the first
        // caller — the existing handler's behavior wins (getOrPut keeps the
        // first), so mismatches silently apply the first caller's setup.
        val existing = notificationHandlers[controllerId]
        if (existing != null && existing.disableMediaSession != disableMediaSession) {
            Log.w(
                TAG,
                "disableMediaSession mismatch on shared handler for controllerId=$controllerId: " +
                    "existing=${existing.disableMediaSession}, requested=$disableMediaSession. " +
                    "Keeping existing. Callers sharing a controllerId must pass a consistent flag."
            )
        }
        return notificationHandlers.getOrPut(controllerId) {
            VideoPlayerNotificationHandler(context, player, eventHandler, disableMediaSession)
        }
    }

    /**
     * Registers a platform view for a controller
     * The callback will be called when another view using the same controller is disposed
     */
    fun registerView(controllerId: Int, viewId: Long, reconnectCallback: () -> Unit) {
        val views = activeViews.getOrPut(controllerId) { mutableMapOf() }
        views[viewId] = reconnectCallback
        Log.d(TAG, "Registered view $viewId for controller $controllerId (total views: ${views.size})")
    }

    /**
     * Unregisters a platform view and notifies other views to reconnect
     */
    fun unregisterView(controllerId: Int, viewId: Long) {
        val views = activeViews[controllerId]
        if (views != null) {
            views.remove(viewId)
            Log.d(TAG, "Unregistered view $viewId for controller $controllerId (remaining views: ${views.size})")

            // Notify all remaining views to reconnect their surfaces
            views.values.forEach { callback ->
                try {
                    callback()
                } catch (e: Exception) {
                    Log.e(TAG, "Error calling reconnect callback: ${e.message}", e)
                }
            }

            // Clean up empty maps
            if (views.isEmpty()) {
                activeViews.remove(controllerId)
            }
        }
    }

    /**
     * Sets available qualities for a controller
     * This ensures qualities persist across view recreations
     */
    fun setQualities(controllerId: Int, qualities: List<Map<String, Any>>) {
        qualitiesCache[controllerId] = qualities
        Log.d(TAG, "Stored ${qualities.size} qualities for controller $controllerId")
    }

    /**
     * Gets available qualities for a controller
     * Returns null if no qualities have been stored for this controller
     */
    fun getQualities(controllerId: Int): List<Map<String, Any>>? {
        return qualitiesCache[controllerId]
    }

    /**
     * Stops all views for a given controller
     */
    fun stopAllViewsForController(controllerId: Int) {
        val player = players[controllerId] ?: return

        // Stop playback
        player.stop()

        Log.d(TAG, "Stopped all views for controller $controllerId")
    }

    /**
     * Removes a player (called when explicitly disposed)
     */
    fun removePlayer(context: Context, controllerId: Int) {
        // First stop all views using this player
        stopAllViewsForController(controllerId)

        // Release notification handler
        notificationHandlers[controllerId]?.release()
        notificationHandlers.remove(controllerId)

        // Release player (unless it's an externally-owned player — owner handles teardown)
        val playerToRelease = players[controllerId]
        if (playerToRelease != null && playerToRelease !== externalPlayer) {
            playerToRelease.release()
        }
        players.remove(controllerId)

        // Remove qualities cache
        qualitiesCache.remove(controllerId)

        // Clear active views for this controller
        activeViews.remove(controllerId)

        Log.d(TAG, "Removed player for controller $controllerId")

        // If no more players, stop the service
        if (players.isEmpty()) {
            stopMediaSessionService(context)
        }
    }

    /**
     * Clears all players (e.g., on logout)
     */
    fun clearAll(context: Context) {
        // Release all notification handlers
        notificationHandlers.values.forEach { it.release() }
        notificationHandlers.clear()

        // Release all players (skip externally-owned player — owner handles teardown)
        players.values.forEach { player ->
            if (player !== externalPlayer) {
                player.release()
            }
        }
        players.clear()

        // Clear qualities cache
        qualitiesCache.clear()

        // Stop the service when clearing all players
        stopMediaSessionService(context)
    }

    /**
     * Stops the MediaSessionService
     */
    private fun stopMediaSessionService(context: Context) {
        // Nuclear reset — clearAll() / last-player-removed code paths only.
        // Per-handler cleanup is handled by VideoPlayerNotificationHandler.release()
        // via clearActiveSessionIfMatches().
        VideoPlayerMediaSessionService.setActiveSession(null)
        val serviceIntent = Intent(context, VideoPlayerMediaSessionService::class.java)
        context.stopService(serviceIntent)
    }
}
