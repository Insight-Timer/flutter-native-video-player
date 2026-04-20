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
    @Volatile
    private var externalPlayer: ExoPlayer? = null

    // Listeners registered by VideoPlayerViews that fell back to an internal
    // ExoPlayer because the external wasn't registered yet. When setExternalPlayer
    // is called with a non-null value, every listener is invoked synchronously
    // with the new external player so views can rebind their surfaces.
    private val externalPlayerListeners = mutableListOf<(ExoPlayer) -> Unit>()

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
     */
    fun setExternalPlayer(player: ExoPlayer?) {
        externalPlayer = player
        if (player != null) {
            // Snapshot + clear + invoke so a listener that registers another
            // listener (shouldn't happen, but defensively) doesn't deadlock.
            val listeners = externalPlayerListeners.toList()
            externalPlayerListeners.clear()
            listeners.forEach { it(player) }
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
     */
    fun addExternalPlayerListener(callback: (ExoPlayer) -> Unit) {
        val existing = externalPlayer
        if (existing != null) {
            callback(existing)
        } else {
            externalPlayerListeners.add(callback)
        }
    }

    /**
     * Remove a previously registered listener. Safe to call even if the listener
     * has already fired (no-op in that case).
     */
    fun removeExternalPlayerListener(callback: (ExoPlayer) -> Unit) {
        externalPlayerListeners.remove(callback)
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
