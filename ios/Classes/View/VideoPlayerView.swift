import Flutter
import UIKit
import AVKit
import AVFoundation
import MediaPlayer
import QuartzCore

// MARK: - Main Video Player View

@objc public class VideoPlayerView: NSObject, FlutterPlatformView, FlutterStreamHandler {
    var playerViewController: AVPlayerViewController
    var player: AVPlayer?
    private var methodChannel: FlutterMethodChannel
    private var channelName: String
    var eventSink: FlutterEventSink?
    var isEventChannelActive: Bool = false
    var isDisposed: Bool = false
    var availableQualities: [[String: Any]] = []
    var qualityLevels: [VideoPlayer.QualityLevel] = []
    var isAutoQuality = false
    var lastBitrateCheck: TimeInterval = 0
    let bitrateCheckInterval: TimeInterval = 5.0 // Check every 5 seconds
    var controllerId: Int?
    var pipController: AVPictureInPictureController?

    /// Stable container returned from view(). The one shared controller's view is
    /// reparented into whichever on-screen host is current (inline ↔ floating).
    let hostContainer = UIView()

    /// Native-controls visibility for the inline slot, restored after the floating
    /// slot hides them.
    var showNativeControls: Bool = true

    // Track if PiP is currently active (for both automatic and manual PiP)
    var isPipCurrentlyActive: Bool = false

    // Track if we're currently in the middle of a PiP restoration
    // This is true from when restoreUserInterfaceForPictureInPictureStop is called
    // until after didStopPictureInPicture completes
    var isPipRestoringUI: Bool = false

    // Track if we've already registered remote command handlers
    // This prevents re-registering and clearing targets unnecessarily
    var hasRegisteredRemoteCommands: Bool = false

    /// Force re-registration of remote commands
    /// Call this when you know the targets might have been removed externally
    func forceReregisterRemoteCommands() {
        print("🔄 Checking if need to re-register remote commands for view \(viewId)")

        // Only force re-registration if we don't already own the commands
        // or if the commands aren't properly set up
        let commandCenter = MPRemoteCommandCenter.shared()
        let hasTargets = commandCenter.playCommand.isEnabled && commandCenter.pauseCommand.isEnabled

        if RemoteCommandManager.shared.isOwner(viewId) && hasTargets {
            print("   → View \(viewId) already owns commands and they're active - skipping re-registration")
            // Just restore Now Playing info without touching remote commands
            if let mediaInfo = currentMediaInfo {
                setupNowPlayingInfo(mediaInfo: mediaInfo)
            }
            return
        }

        print("   → Re-registering remote commands for view \(viewId)")
        hasRegisteredRemoteCommands = false
        if let mediaInfo = currentMediaInfo {
            setupNowPlayingInfo(mediaInfo: mediaInfo)
        }
    }

    // Store the platform view ID for registration
    var viewId: Int64 = 0
    
    // Store whether automatic PiP was requested in creation params
    var canStartPictureInPictureAutomatically: Bool = true

    // Separate player view controller for fullscreen (prevents removing embedded view)
    var fullscreenPlayerViewController: AVPlayerViewController?

    // When true, this platform view is the Dart fullscreen host and uses its own AVPlayerViewController
    // (same AVPlayer) so the inline view never loses its shared view. Cleared in deinit.
    var isDartFullscreenView: Bool = false

    // Store media info for Now Playing
    var currentMediaInfo: [String: Any]?
    var timeObserver: Any?

    // Track if this is a shared player (to avoid sending duplicate initialization events)
    var isSharedPlayer: Bool = false

    // AirPlay route detector
    var routeDetector: AVRouteDetector?

    // Store desired playback speed
    var desiredPlaybackSpeed: Float = 1.0

    // Store HDR setting
    var enableHDR: Bool = false

    // MARK: - Native Layout (orientation transition workaround)
    // When true, the player view has been reparented to the root view with Auto Layout
    // constraints so it stays centered during iOS orientation animations, bypassing
    // Flutter's layout which looks broken during transitions.
    var isUsingNativeLayout: Bool = false
    var nativeLayoutConstraints: [NSLayoutConstraint] = []
    weak var flutterParentView: UIView?
    var flutterFrame: CGRect = .zero
    var portraitPlayerRectInRoot: CGRect?

    // Store looping setting
    var enableLooping: Bool = false

    // Store preferred render mode
    var useAspectFill: Bool = false
    var lastEmittedVideoWidth: Int = 0
    var lastEmittedVideoHeight: Int = 0

    // Track if app is in background to keep audio playing on screen lock
    var isInBackground: Bool = false
    var lastKnownRate: Float = 0.0

    // Playback intent for PIP dismiss, kept current by `timeControlStatus`
    // KVO — the dismiss-pause makes the live rate unreliable at willStop.
    var isPlaybackActive: Bool = false
    var lastPlayingToPausedAt: Date?
    
    // DRM handler for protected content
    var drmHandler: VideoPlayerDrmHandler?

    // Track which KVO observers were actually registered on this view, so
    // `deinit` only calls `removeObserver` for them. Without this guard,
    // secondary / shared-player views that never reach the
    // `addObservers(to:)` code path (player had no `currentItem` at init
    // and no later `loadUrl` call routes through this view) would still
    // attempt to unregister at `deinit` and trip
    // `_removeObserver:forProperty:` — crashing the app whenever a
    // floating-preview view is disposed (e.g. playlist track change).
    var didRegisterPlayerItemObservers: Bool = false
    var didRegisterPlayerObservers: Bool = false


    public init(
        frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?,
        binaryMessenger messenger: FlutterBinaryMessenger
    ) {
        print("Creating VideoPlayerView with id: \(viewId)")
        self.viewId = viewId
        channelName = "native_video_player_\(viewId)"
        methodChannel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: messenger
        )

        // Extract controller ID from args to get shared player and view controller
        let argsDict = args as? [String: Any]
        let isDartFullscreen = argsDict?["isDartFullscreen"] as? Bool ?? false

        // True when a floating collapse/expand handoff is already active for this
        // controller. Then setAutomaticPipView owns the shared controller's slot,
        // so this view (a recreated inline) must reuse it and not reconfigure/mount.
        var hasHandoffContext = false
        if #available(iOS 14.2, *), let cid = argsDict?["controllerId"] as? Int {
            hasHandoffContext = SharedPlayerManager.shared.automaticPipContext(for: cid) != nil
        }

        if let args = argsDict,
           let controllerIdValue = args["controllerId"] as? Int {
            controllerId = controllerIdValue

            // Get or create shared player AND view controller
            // This ensures the view controller persists across platform view disposal
            // so PiP delegate callbacks continue to work even when navigating away
            let (sharedPlayer, sharedViewController, alreadyExisted) =
                SharedPlayerManager.shared.getOrCreatePlayerAndViewController(for: controllerIdValue)

            player = sharedPlayer
            isSharedPlayer = alreadyExisted

            if isDartFullscreen {
                // Floating host reuses the ONE shared controller (a second/extra
                // controller won't auto-PiP); its view is reparented in on collapse.
                playerViewController = sharedViewController
                isDartFullscreenView = true
            } else {
                if alreadyExisted && !hasHandoffContext {
                    // Second platform view for this controller with NO floating handoff
                    // (list↔detail): a dedicated VC per slot avoids black screen.
                    let displayVC = AVPlayerViewController()
                    displayVC.player = sharedPlayer
                    playerViewController = displayVC
                    print("✅ Created dedicated AVPlayerViewController for shared controller (controller ID: \(controllerIdValue)) - avoids black screen when navigating list↔detail")
                } else {
                    // First view, or a recreated inline while a floating handoff is
                    // active: reuse the ONE shared controller so no second controller
                    // is bound to the player and blocks auto-PiP.
                    playerViewController = sharedViewController
                    print("✅ Reusing the shared AVPlayerViewController for controller ID: \(controllerIdValue)")
                }
            }
        } else {
            // Fallback: create new instances if no controller ID provided
            print("No controller ID provided, creating new player and view controller")
            playerViewController = AVPlayerViewController()
            player = AVPlayer()

            // Configure for background playback
            if #available(iOS 15.0, *) {
                player?.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
                print("✅ Set audiovisualBackgroundPlaybackPolicy for non-shared player")
            }

            // Assign player to view controller
            playerViewController.player = player
        }

        super.init()

        // Configure playback controls
        let showControls = (args as? [String: Any])?["showNativeControls"] as? Bool ?? true
        showNativeControls = showControls
        useAspectFill = (args as? [String: Any])?["useAspectFill"] as? Bool ?? false

        // Don't reconfigure the shared controller when setAutomaticPipView owns it:
        // the floating host, or a recreated inline while a handoff is active. Doing
        // so would steal the on-screen slot's delegate/zoom/controls.
        if !isDartFullscreenView && !hasHandoffContext {
            playerViewController.showsPlaybackControls = showControls
            playerViewController.delegate = self
            applyVideoGravity(useAspectFill)
            // Disable automatic Now Playing updates - we'll handle it manually
            playerViewController.updatesNowPlayingInfoCenter = false
        }

        // Extract configuration from Flutter args
        if let args = args as? [String: Any] {
            // PiP configuration from args
            let argsAllowsPiP = args["allowsPictureInPicture"] as? Bool ?? true
            let argsCanStartAutomatically = args["canStartPictureInPictureAutomatically"] as? Bool ?? true
            let argsAllowsVideoFrameAnalysis = args["allowsVideoFrameAnalysis"] as? Bool ?? true
            let argsShowNativeControls = args["showNativeControls"] as? Bool ?? true

            // HDR configuration from args
            enableHDR = args["enableHDR"] as? Bool ?? false

            // Looping configuration from args
            let argsEnableLooping = args["enableLooping"] as? Bool ?? false
            // Prefer any live value another view already stored for this controller;
            // otherwise seed the shared state from this view's args so both inline
            // and Dart-fullscreen views agree.
            if let controllerIdValue = controllerId {
                if let shared = SharedPlayerManager.shared.storedLoopingValue(for: controllerIdValue) {
                    enableLooping = shared
                } else {
                    enableLooping = argsEnableLooping
                    SharedPlayerManager.shared.setLoopingEnabled(for: controllerIdValue, enabled: argsEnableLooping)
                }
            } else {
                enableLooping = argsEnableLooping
            }

            // For shared players, try to get PiP settings from SharedPlayerManager
            // This ensures PiP settings persist across all views using the same controller
            if let controllerIdValue = controllerId {
                if let sharedSettings = SharedPlayerManager.shared.getPipSettings(for: controllerIdValue) {
                    // Use existing shared settings
                    self.canStartPictureInPictureAutomatically = sharedSettings.canStartPictureInPictureAutomatically
                    playerViewController.allowsPictureInPicturePlayback = sharedSettings.allowsPictureInPicture
                    print("✅ Using shared PiP settings for controller \(controllerIdValue) - allows: \(sharedSettings.allowsPictureInPicture), autoStart: \(sharedSettings.canStartPictureInPictureAutomatically)")
                } else {
                    // First view for this controller - store the settings
                    self.canStartPictureInPictureAutomatically = argsCanStartAutomatically
                    playerViewController.allowsPictureInPicturePlayback = argsAllowsPiP
                    SharedPlayerManager.shared.setPipSettings(
                        for: controllerIdValue,
                        allowsPictureInPicture: argsAllowsPiP,
                        canStartPictureInPictureAutomatically: argsCanStartAutomatically,
                        showNativeControls: argsShowNativeControls
                    )
                    print("✅ Stored new PiP settings for controller \(controllerIdValue) - allows: \(argsAllowsPiP), autoStart: \(argsCanStartAutomatically)")
                }
            } else {
                // Non-shared player - use settings from args
                self.canStartPictureInPictureAutomatically = argsCanStartAutomatically
                playerViewController.allowsPictureInPicturePlayback = argsAllowsPiP
                print("✅ PiP settings for non-shared player - allows: \(argsAllowsPiP), autoStart: \(argsCanStartAutomatically)")
            }

            if #available(iOS 14.2, *), !isDartFullscreenView {
                // Start disabled (armed on play/handoff). Skip for the floating host
                // so it never disarms the already-armed shared controller.
                playerViewController.canStartPictureInPictureAutomaticallyFromInline = false
            } else if #unavailable(iOS 14.2) {
                print("⚠️ Automatic PiP requires iOS 14.2+, current device doesn't support it")
            }

            if #available(iOS 16.0, *) {
                playerViewController.allowsVideoFrameAnalysis = argsAllowsVideoFrameAnalysis
            }

            // Store media info if provided during initialization
            // This ensures we have the correct media info even for shared players
            if let mediaInfo = args["mediaInfo"] as? [String: Any] {
                currentMediaInfo = mediaInfo
                print("📱 Stored media info during init: \(mediaInfo["title"] ?? "Unknown")")

                // Also store in SharedPlayerManager to persist across view recreations
                if let controllerIdValue = controllerId {
                    SharedPlayerManager.shared.setMediaInfo(for: controllerIdValue, mediaInfo: mediaInfo)
                }
            }
        }
        
        // Register this view with the SharedPlayerManager
        if let controllerIdValue = controllerId {
            SharedPlayerManager.shared.registerVideoPlayerView(self, viewId: viewId)
            print("✅ Registered VideoPlayerView for controller \(controllerIdValue), viewId: \(viewId)")

            // Setup controller-level event channel (if not already set up)
            // This enables persistent event delivery for PiP and AirPlay
            NativeVideoPlayerPlugin.setupControllerEventChannel(for: controllerIdValue)

            // If this controller is currently the one with automatic PiP enabled OR if the player is playing,
            // this new view should become the primary view and get automatic PiP
            // BUT ONLY if manual PiP is not active
            if #available(iOS 14.2, *) {
                let isActiveForAutoPiP = SharedPlayerManager.shared.isControllerActiveForAutoPiP(controllerIdValue)
                let isPlaying = player?.rate ?? 0 > 0

                if isActiveForAutoPiP || isPlaying {
                    print("🎬 Controller state - activeForAutoPiP: \(isActiveForAutoPiP), isPlaying: \(isPlaying)")
                    // Honor runtime PIP hard-disable across view reconstruction.
                    let storedAllowsPip = SharedPlayerManager.shared.getPipSettings(for: controllerIdValue)?.allowsPictureInPicture ?? true
                    if !storedAllowsPip {
                        // Skip — runtime override has disabled PIP.
                    } else if canStartPictureInPictureAutomatically {
                        // Check if manual PiP is active - if so, skip re-enabling automatic PiP
                        if SharedPlayerManager.shared.isManualPiPActive(controllerIdValue) {
                            print("   ⚠️ Skipping automatic PiP re-enable - manual PiP is active")
                        } else if !isDartFullscreenView,
                                  SharedPlayerManager.shared.automaticPipContext(for: controllerIdValue) == nil {
                            // Legacy arming only when setAutomaticPipView was never used;
                            // otherwise it owns arming (the reapply below targets the view).
                            SharedPlayerManager.shared.setPrimaryView(viewId, for: controllerIdValue)
                            SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: true)
                            print("   → Set new view as primary and enabled automatic PiP (viewId: \(viewId))")
                        }
                    } else {
                        print("   ⚠️ Cannot enable automatic PiP - canStartPictureInPictureAutomatically is false")
                    }
                }

                // Re-apply any pending collapse/expand handoff for this controller
                // (e.g. the floating view registering after the collapse signal).
                SharedPlayerManager.shared.reapplyAutomaticPipContext(for: controllerIdValue, registeringIsFullscreen: isDartFullscreenView)
            }
        }

        print("Setting up method channel: \(channelName)")
        // Set up method call handler
        print("Setting method handler for channel: \(channelName)")
        methodChannel.setMethodCallHandler({ [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
            guard let self = self else {
                result(FlutterError(code: "DISPOSED", message: "VideoPlayerView was disposed", details: nil))
                return
            }
            print("[\(self.channelName)] Received method call: \(call.method)")
            self.handleMethodCall(call: call, result: result)
        })
        
        // Set up event channel
        let eventChannel = FlutterEventChannel(
            name: "native_video_player_\(viewId)",
            binaryMessenger: messenger
        )
        eventChannel.setStreamHandler(self)

        // Set up observers for shared players if there's already a loaded video
        // The initial state event will be sent when onListen is called
        if isSharedPlayer, let currentItem = player?.currentItem {
            addObservers(to: currentItem)
            // Also set up periodic time observer for this new view
            setupPeriodicTimeObserver()
        }

        // Observe app entering foreground to restore Now Playing info
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        print("✅ Registered foreground notification observer for view \(viewId)")

        // Observe app entering background (for screen lock detection)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        print("✅ Registered background notification observer for view \(viewId)")

        // Re-arm auto-PIP at willResignActive: closes the window right after
        // a runtime PIP re-enable where AVKit's view-active state is still
        // settling and the initial flag set would otherwise be ignored.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )

        // Observe audio session interruptions
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        print("✅ Registered audio session interruption observer for view \(viewId)")

        // Set up AirPlay route detector (iOS 11.0+)
        if #available(iOS 11.0, *) {
            setupAirPlayRouteDetector()
        }

        // Mount the controller's view into the host. The floating host stays empty
        // until collapse moves the shared controller's view in. When a handoff is
        // already active, skip — reapplyAutomaticPipContext (in registration) mounts
        // the shared view into the correct current slot.
        if !isDartFullscreenView && !hasHandoffContext {
            mountControllerView(playerViewController, collapsed: false, setSlotConfig: false)
        }
    }

    public func view() -> UIView {
        return hostContainer
    }

    /// Reparents `controller`'s view into this view's host container; with
    /// setSlotConfig it also applies the slot config (delegate/controls/zoom/arm).
    func mountControllerView(_ controller: AVPlayerViewController, collapsed: Bool, setSlotConfig: Bool) {
        let playerView: UIView = controller.view
        let didReparent = playerView.superview !== hostContainer
        if didReparent {
            // Reparent without implicit animation to minimize black flash.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerView.removeFromSuperview()
            playerView.translatesAutoresizingMaskIntoConstraints = true
            playerView.frame = hostContainer.bounds
            playerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            hostContainer.addSubview(playerView)
            CATransaction.commit()
        }

        // Slot config only on the handoff path, not at init — arming every
        // controller at init would re-arm two controllers in the list↔detail case.
        if setSlotConfig {
            controller.delegate = self
            // Floating slot hides controls; inline slot keeps controls + zoom.
            controller.showsPlaybackControls = collapsed ? false : showNativeControls
            if !collapsed {
                controller.videoGravity = useAspectFill ? .resizeAspectFill : .resizeAspect
            }
            // Re-arm auto-PiP. Restore allowsPictureInPicturePlayback first — a prior
            // PiP session can leave it false, which would silently skip arming and
            // break auto-PiP on the next background.
            var armFlag = false
            if #available(iOS 14.2, *), canStartPictureInPictureAutomatically {
                let allowsPip = controllerId.flatMap {
                    SharedPlayerManager.shared.getPipSettings(for: $0)?.allowsPictureInPicture
                } ?? true
                controller.allowsPictureInPicturePlayback = allowsPip
                controller.canStartPictureInPictureAutomaticallyFromInline = allowsPip
                armFlag = allowsPip
            }
            // FLTR-20376 TEMP: pinpoint why collapse→bg doesn't auto-PiP the floating view.
            print("🐛 [PIP] mount view=\(isDartFullscreenView ? "floating" : "inline") viewId=\(viewId) reparented=\(didReparent) canStartAuto(instance)=\(canStartPictureInPictureAutomatically) allowsPip=\(controller.allowsPictureInPicturePlayback) armedFlag=\(armFlag) viewInWindow=\(controller.viewIfLoaded?.window != nil) hostBounds=\(hostContainer.bounds) vc=\(ObjectIdentifier(controller))")
        }
    }


    // MARK: - Native Layout Overlay

    /// Reparents the player view from Flutter's container to the root view
    /// with edge-pinned Auto Layout constraints. The live video rotates
    /// smoothly with iOS while Flutter re-layouts underneath.
    func handleUseNativeLayout(result: @escaping FlutterResult) {
        guard !isUsingNativeLayout else {
            result(nil)
            return
        }

        let playerView = playerViewController.view!
        guard let rootView = UIApplication.shared.delegate?.window??.rootViewController?.view else {
            print("⚠️ [NativeLayout] Could not find root view — skipping")
            result(FlutterError(code: "NO_ROOT_VIEW", message: "Could not find root view controller", details: nil))
            return
        }

        flutterParentView = playerView.superview
        flutterFrame = playerView.frame

        // Get player's exact screen position before reparenting.
        let currentRectInRoot = playerView.convert(playerView.bounds, to: rootView)

        // Remember portrait position for the reverse rotation.
        let isCurrentlyPortrait = rootView.bounds.height > rootView.bounds.width
        if isCurrentlyPortrait {
            portraitPlayerRectInRoot = currentRectInRoot
        }

        // Reparent into a container on the root view. The container is
        // edge-pinned; the player view starts at its exact screen position
        // and animates to fullscreen (or back to portrait rect) when iOS
        // rotation changes the bounds.
        let container = RotationReparentContainer(
            childView: playerView,
            initialRect: currentRectInRoot,
            portraitRect: portraitPlayerRectInRoot
        )
        container.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(container)

        nativeLayoutConstraints = [
            container.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            container.topAnchor.constraint(equalTo: rootView.topAnchor),
            container.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ]
        NSLayoutConstraint.activate(nativeLayoutConstraints)

        isUsingNativeLayout = true
        print("✅ [NativeLayout] Player view reparented to root view")
        result(nil)
    }

    /// Returns the player view to Flutter's container.
    func handleUseFlutterLayout(result: @escaping FlutterResult) {
        guard isUsingNativeLayout else {
            result(nil)
            return
        }

        let playerView = playerViewController.view!

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Remove the container (which holds the player view) from root.
        let container = playerView.superview
        NSLayoutConstraint.deactivate(nativeLayoutConstraints)
        nativeLayoutConstraints = []

        // Move player view back to Flutter's container.
        playerView.removeFromSuperview()
        playerView.translatesAutoresizingMaskIntoConstraints = true

        if let parent = flutterParentView {
            parent.addSubview(playerView)
            playerView.frame = parent.bounds
            playerView.layoutIfNeeded()
        } else {
            print("⚠️ [NativeLayout] Flutter parent was deallocated")
        }

        // Clean up the container.
        container?.removeFromSuperview()

        CATransaction.commit()

        isUsingNativeLayout = false
        flutterParentView = nil
        print("✅ [NativeLayout] Player view returned to Flutter layout")
        result(nil)
    }

    // MARK: - Audio Session Management

    /// Prepares and activates the audio session for video playback
    /// This MUST be called before starting playback to ensure audio continues when screen locks
    func prepareAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            print("✅ AVAudioSession configured for movie playback and activated")
        } catch {
            print("❌ Audio session error: \(error.localizedDescription)")
        }
    }

    public func handleMethodCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
        print("Handling method call: \(call.method) on channel: \(channelName)")
        switch call.method {
        case "load":
            handleLoad(call: call, result: result)
        case "play":
            handlePlay(result: result)
        case "pause":
            handlePause(result: result)
        case "seekTo":
            handleSeekTo(call: call, result: result)
        case "setVolume":
            handleSetVolume(call: call, result: result)
        case "setSpeed":
            handleSetSpeed(call: call, result: result)
        case "setLooping":
            handleSetLooping(call: call, result: result)
        case "setQuality":
            handleSetQuality(call: call, result: result)
        case "getAvailableQualities":
            // First check if we have qualities in this view instance
            if !availableQualities.isEmpty {
                result(availableQualities)
            } else if let controllerIdValue = controllerId,
                      let cachedQualities = SharedPlayerManager.shared.getQualities(for: controllerIdValue) {
                // If view instance is empty but cache has qualities, restore them
                availableQualities = cachedQualities
                if let cachedQualityLevels = SharedPlayerManager.shared.getQualityLevels(for: controllerIdValue) {
                    qualityLevels = cachedQualityLevels
                }
                print("🔄 Restored \(cachedQualities.count) qualities from cache for controller \(controllerIdValue)")
                result(cachedQualities)
            } else {
                result(availableQualities)
            }
        case "getAvailableSubtitleTracks":
            handleGetAvailableSubtitleTracks(result: result)
        case "setSubtitleTrack":
            handleSetSubtitleTrack(call: call, result: result)
        case "setVideoTrackDisabled":
            handleSetVideoTrackDisabled(call: call, result: result)
        case "enterFullScreen":
            handleEnterFullScreen(result: result)
        case "exitFullScreen":
            handleExitFullScreen(result: result)
        case "isPictureInPictureAvailable":
            handleIsPictureInPictureAvailable(result: result)
        case "enterPictureInPicture":
            handleEnterPictureInPicture(result: result)
        case "exitPictureInPicture":
            handleExitPictureInPicture(result: result)
        case "enableAutomaticInlinePip":
            handleEnableAutomaticInlinePip(result: result)
        case "disableAutomaticInlinePip":
            handleDisableAutomaticInlinePip(result: result)
        case "setAutomaticPipView":
            handleSetAutomaticPipView(call: call, result: result)
        case "setAllowsPictureInPicture":
            handleSetAllowsPictureInPicture(call: call, result: result)
        case "setRequiresLinearPlayback":
            handleSetRequiresLinearPlayback(call: call, result: result)
        case "setShowNativeControls":
            handleSetShowNativeControls(call: call, result: result)
        case "setUseAspectFill":
            handleSetUseAspectFill(call: call, result: result)
        case "getVideoDimensions":
            handleGetVideoDimensions(result: result)
        case "useNativeLayout":
            handleUseNativeLayout(result: result)
        case "useFlutterLayout":
            handleUseFlutterLayout(result: result)
        case "ensureSurfaceConnected":
            // No-op on iOS; each platform view uses its own AVPlayerViewController when shared.
            result(nil)
        case "isAirPlayAvailable":
            handleIsAirPlayAvailable(result: result)
        case "showAirPlayPicker":
            handleShowAirPlayPicker(result: result)
        case "disconnectAirPlay":
            handleDisconnectAirPlay(result: result)
        case "startAirPlayDetection":
            handleStartAirPlayDetection(result: result)
        case "stopAirPlayDetection":
            handleStopAirPlayDetection(result: result)
        case "dispose":
            handleDispose(result: result)
        case "updateTrackNavFlags":
            handleUpdateTrackNavFlags(call: call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Refreshes the lock-screen / Control Center prev-next button availability
    /// for the currently-loaded media. Used by playlist hosts after the playing
    /// item is reordered/shuffled — the `mediaInfo` baked in at `load` time has
    /// gone stale and the OS buttons need to follow the new queue neighbours.
    private func handleUpdateTrackNavFlags(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any] else {
            result(FlutterError(code: "INVALID_ARGS", message: "updateTrackNavFlags expects a Map", details: nil))
            return
        }
        let showNext = args["showSystemNextTrackControl"] as? Bool ?? false
        let showPrev = args["showSystemPreviousTrackControl"] as? Bool ?? false
        refreshSystemTrackControlsAvailability(
            showSystemNextTrackControl: showNext,
            showSystemPreviousTrackControl: showPrev
        )
        result(nil)
    }

    func invalidateEventChannel() {
        isEventChannelActive = false
        eventSink = nil
    }

    public func sendEvent(_ name: String, data: [String: Any]? = nil) {
        guard isEventChannelActive, !isDisposed else {
            return
        }

        var event: [String: Any] = ["event": name]
        if let data = data {
            event.merge(data) { (_, new) in
                new
            }
        }

        let emitEvent = { [weak self] in
            guard let self = self,
                  self.isEventChannelActive,
                  !self.isDisposed,
                  let eventSink = self.eventSink else {
                return
            }
            eventSink(event)
        }

        if Thread.isMainThread {
            emitEvent()
            return
        }

        DispatchQueue.main.async(execute: emitEvent)
    }

    private func handleSetUseAspectFill(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        let enabled = args?["enabled"] as? Bool ?? false
        if useAspectFill == enabled {
            result(nil)
            return
        }
        useAspectFill = enabled
        applyVideoGravity(enabled)
        result(nil)
    }

    private func applyVideoGravity(_ enabled: Bool) {
        if Thread.isMainThread {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            UIView.performWithoutAnimation {
                playerViewController.videoGravity = enabled ? .resizeAspectFill : .resizeAspect
                playerViewController.view.setNeedsLayout()
                playerViewController.view.layoutIfNeeded()
            }
            CATransaction.commit()
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.applyVideoGravity(enabled)
        }
    }

    func getCurrentVideoDimensions() -> [String: Int]? {
        guard let currentItem = player?.currentItem else {
            return nil
        }
        let presentationSize = currentItem.presentationSize
        let width = Int(presentationSize.width.rounded())
        let height = Int(presentationSize.height.rounded())
        if width > 0 && height > 0 {
            return ["width": width, "height": height]
        }
        return nil
    }

    func appendVideoDimensions(to payload: inout [String: Any]) {
        guard let dimensions = getCurrentVideoDimensions() else {
            return
        }
        payload["videoWidth"] = dimensions["width"]
        payload["videoHeight"] = dimensions["height"]
    }

    private func handleGetVideoDimensions(result: @escaping FlutterResult) {
        if let dimensions = getCurrentVideoDimensions() {
            result(dimensions)
            return
        }
        result(nil)
    }

    /// Cleans up remote command ownership, attempting to transfer to another view if possible
    /// This is called from both deinit and handleDispose to avoid duplication
    func cleanupRemoteCommandOwnership() {
        // Only proceed if this view owns the remote commands
        guard RemoteCommandManager.shared.isOwner(viewId) else {
            return
        }

        print("🎛️ View \(viewId) owned remote commands - attempting transfer")

        // Try to transfer ownership to another view with the same controller
        var ownershipTransferred = false
        if let controllerIdValue = controllerId,
           let alternativeView = SharedPlayerManager.shared.findAnotherViewForController(controllerIdValue, excluding: viewId) {
            print("🎛️ Transferring ownership to view \(alternativeView.viewId)")

            // Transfer ownership by setting up Now Playing info on the alternative view
            var mediaInfo = alternativeView.currentMediaInfo

            // Fallback: Try to get media info from SharedPlayerManager
            if mediaInfo == nil {
                mediaInfo = SharedPlayerManager.shared.getMediaInfo(for: controllerIdValue)
                if mediaInfo != nil {
                    print("📱 Retrieved media info from SharedPlayerManager for ownership transfer")
                    alternativeView.currentMediaInfo = mediaInfo
                }
            }

            if let mediaInfo = mediaInfo {
                alternativeView.setupNowPlayingInfo(mediaInfo: mediaInfo)
                ownershipTransferred = true
                print("✅ Ownership transferred to view \(alternativeView.viewId)")
            } else {
                print("⚠️ Alternative view has no media info - cannot transfer")
            }
        }

        // CRITICAL: If no transfer was possible BUT PiP is active OR restoring, DO NOT clear Now Playing info
        // PiP needs the media controls to work, so we must preserve them
        if !ownershipTransferred {
            // Check if PiP is active:
            // 1. On this view (isPipCurrentlyActive)
            // 2. On ANY view for this controller (isPipActiveForController)
            // 3. Currently restoring UI (isPipRestoringUI)
            let isPipActiveForController = controllerId.flatMap { SharedPlayerManager.shared.isPipActiveForController($0) } ?? false

            if isPipCurrentlyActive || isPipRestoringUI || isPipActiveForController {
                if isPipCurrentlyActive {
                    print("⚠️ No transfer possible but PiP is active on this view - keeping Now Playing info")
                } else if isPipRestoringUI {
                    print("⚠️ No transfer possible but PiP is restoring UI - keeping Now Playing info")
                } else {
                    print("⚠️ No transfer possible but PiP is active on another view for controller \(controllerId ?? -1) - keeping Now Playing info")
                }
                // Just clear the ownership flag, but keep the Now Playing info and remote commands active
                RemoteCommandManager.shared.clearOwner(viewId)
                // Do NOT clear nowPlayingInfo or remove targets while PiP is active or restoring
            } else {
                RemoteCommandManager.shared.clearOwner(viewId)
                // Identity-guarded clear: only wipe Now Playing info if it still
                // belongs to this view. setupNowPlayingInfo / artwork updates /
                // updateNowPlayingPlaybackTime all stamp the info with
                // NowPlayingOwnership.key = viewId. If another player (audio
                // fork, sibling video view, ambient mixer) has already
                // overwritten it, their write replaced our tag, so we skip the
                // clear and avoid wiping their setup — the same race the
                // previous "never clear" rule was guarding against.
                let currentInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo
                if let ownerId = currentInfo?[NowPlayingOwnership.key] as? Int64, ownerId == viewId {
                    print("🗑️ View \(viewId) still owns Now Playing info - clearing")
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                } else {
                    print("🗑️ View \(viewId) no longer owns Now Playing info - leaving it alone")
                }
                // Remote command targets are left registered. They are harmless:
                // each handler checks RemoteCommandManager.isOwner() (now
                // cleared) and holds a [weak self] that becomes nil after
                // deallocation — both guards cause them to return
                // .commandFailed without side effects.
            }
        }
    }

    /// Emits all current player states to ensure UI is in sync
    /// This is useful after events like exiting PiP where the UI needs to refresh
    public func emitCurrentState() {
        guard let player = player, let currentItem = player.currentItem else {
            print("[\(channelName)] No player or item available to emit state")
            return
        }

        print("[\(channelName)] Emitting current state after PiP exit")

        // Emit current time and duration
        let currentTimeSeconds = CMTimeGetSeconds(player.currentTime())
        let durationSeconds = CMTimeGetSeconds(currentItem.duration)

        if !currentTimeSeconds.isNaN && !durationSeconds.isNaN && durationSeconds > 0 {
            let duration = Int(durationSeconds * 1000)
            let position = Int(currentTimeSeconds * 1000)

            // Get buffered position
            var bufferedSeconds = 0.0
            let timeRanges = currentItem.loadedTimeRanges
            if !timeRanges.isEmpty {
                let bufferedRange = timeRanges.last!.timeRangeValue
                let bufferedEnd = CMTimeAdd(bufferedRange.start, bufferedRange.duration)
                bufferedSeconds = CMTimeGetSeconds(bufferedEnd)
            }
            let bufferedPosition = Int(bufferedSeconds * 1000)

            var payload: [String: Any] = [
                "position": position,
                "duration": duration,
                "bufferedPosition": bufferedPosition,
                "isBuffering": player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            ]
            appendVideoDimensions(to: &payload)
            sendEvent("timeUpdate", data: payload)
            print("[\(channelName)] Emitted timeUpdate with duration: \(duration)ms")
        }

        // Emit current playback state
        switch player.timeControlStatus {
        case .playing:
            print("[\(channelName)] Emitting play state")
            sendEvent("play")
        case .paused:
            print("[\(channelName)] Emitting pause state")
            sendEvent("pause")
        case .waitingToPlayAtSpecifiedRate:
            print("[\(channelName)] Emitting buffering state")
            sendEvent("buffering")
        @unknown default:
            break
        }

        // Emit current PiP state
        let isPipActive = isPipCurrentlyActive ||
                          (controllerId.flatMap { SharedPlayerManager.shared.isPipActiveForController($0) } ?? false)

        if isPipActive {
            print("[\(channelName)] Emitting pipStart state")
            sendEvent("pipStart", data: ["isPictureInPicture": true])
        } else {
            print("[\(channelName)] Emitting pipStop state")
            sendEvent("pipStop", data: ["isPictureInPicture": false])
        }
    }

    // MARK: - FlutterStreamHandler
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        print("[\(channelName)] Event channel listener attached")
        isDisposed = false
        isEventChannelActive = true
        self.eventSink = events

        // Send initial state event when listener is attached
        if isSharedPlayer {
            // For shared players, only send current playback state and position
            if let player = player, let currentItem = player.currentItem {
                let currentTimeSeconds = CMTimeGetSeconds(player.currentTime())
                let durationSeconds = CMTimeGetSeconds(currentItem.duration)

                // Check for NaN or invalid times
                if currentTimeSeconds.isNaN || durationSeconds.isNaN {
                    print("[\(channelName)] Skipping timeUpdated event — invalid currentTime or duration")
                } else {
                    let duration = Int(durationSeconds * 1000)
                    let position = Int(currentTimeSeconds * 1000)
                    var payload: [String: Any] = ["position": position, "duration": duration]
                    appendVideoDimensions(to: &payload)
                    sendEvent("timeUpdated", data: payload)
                }

                // Send current playback state
                switch player.timeControlStatus {
                case .playing:
                    print("[\(channelName)] Sending play event to new listener")
                    sendEvent("play")
                case .paused:
                    print("[\(channelName)] Sending pause event to new listener")
                    sendEvent("pause")
                case .waitingToPlayAtSpecifiedRate:
                    print("[\(channelName)] Sending buffering event to new listener")
                    sendEvent("buffering")
                @unknown default:
                    break
                }
            }

        } else {
            // For new players, send isInitialized event
            print("[\(channelName)] Sending isInitialized event to new listener")
            sendEvent("isInitialized")
        }

        // Send initial AirPlay availability state
        if #available(iOS 11.0, *) {
            if let detector = routeDetector {
                let isAvailable = detector.multipleRoutesDetected
                print("[\(channelName)] Sending initial AirPlay availability: \(isAvailable)")
                sendEvent("airPlayAvailabilityChanged", data: ["isAvailable": isAvailable])
            }
        }

        // Send initial AirPlay connection state
        // Check at system level (audio route) rather than just this player's state
        // This ensures we detect if ANY player in the app is using AirPlay
        print("[\(channelName)] 🔍 Checking initial AirPlay state on event listener attach")
        let deviceName = getAirPlayDeviceName()
        let isSystemAirPlayActive = deviceName != nil

        if let player = player {
            // Check if THIS specific player is using AirPlay
            let isPlayerAirPlayActive = player.isExternalPlaybackActive

            // We're connected if either:
            // 1. This player is actively using AirPlay, OR
            // 2. AirPlay device is detected in audio route (another player might be using it)
            let isConnected = isPlayerAirPlayActive || isSystemAirPlayActive

            if isConnected {
                print("[\(channelName)] ✅ AirPlay active on init:")
                print("   - Player active: \(isPlayerAirPlayActive)")
                print("   - System active: \(isSystemAirPlayActive)")
                print("   - Device: \(deviceName ?? "nil")")

                var eventData: [String: Any] = ["isConnected": true, "isConnecting": false]
                if let deviceName = deviceName {
                    eventData["deviceName"] = deviceName
                }
                sendEvent("airPlayConnectionChanged", data: eventData)

                // If device name is not available yet, start retry sequence
                if deviceName == nil {
                    print("[\(channelName)] ⏳ Device name not available on init, starting retry sequence...")
                    retryGetAirPlayDeviceName(attempt: 1, maxAttempts: 4)
                }
            } else {
                // Not connected at system or player level
                print("[\(channelName)] ❌ AirPlay not connected on init")
                sendEvent("airPlayConnectionChanged", data: ["isConnected": false, "isConnecting": false])
            }
        }

        // Send initial PiP state
        // Check if PiP is currently active on this view or any view for the same controller
        print("[\(channelName)] 🔍 Checking initial PiP state on event listener attach")
        let isPipActive = isPipCurrentlyActive ||
                          (controllerId.flatMap { SharedPlayerManager.shared.isPipActiveForController($0) } ?? false)

        if isPipActive {
            print("[\(channelName)] ✅ PiP is active on init")
            sendEvent("pipStart", data: ["isPictureInPicture": true])
        } else {
            print("[\(channelName)] ℹ️ PiP is not active on init")
            // Send pipStop to ensure Flutter knows PiP is not active
            sendEvent("pipStop", data: ["isPictureInPicture": false])
        }

        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        print("[\(channelName)] Event channel listener detached")
        invalidateEventChannel()
        return nil
    }

    deinit {
        print("VideoPlayerView deinit for channel: \(channelName), viewId: \(viewId)")
        isDisposed = true
        invalidateEventChannel()

        // Clean up rotation container if still on root view.
        if isUsingNativeLayout {
            let playerView = playerViewController.view!
            let container = playerView.superview
            playerView.removeFromSuperview()
            container?.removeFromSuperview()
            isUsingNativeLayout = false
        }

        // Use the isPipCurrentlyActive flag to check if PiP is active
        let isPipActiveNow = isPipCurrentlyActive

        // Try to stop PiP gracefully if it was active
        if isPipActiveNow {
            if #available(iOS 14.0, *) {
                if let pipCtrl = pipController, pipCtrl.isPictureInPictureActive {
                    pipCtrl.stopPictureInPicture()
                }
            }
        }

        // Clean up remote command ownership (transfer to another view if possible)
        cleanupRemoteCommandOwnership()

        // Handle automatic PiP transfer for shared players
        // If this was the primary view (the one with automatic PiP enabled) OR if the player is playing,
        // we need to transfer automatic PiP to another view using the same controller
        if #available(iOS 14.2, *), let controllerIdValue = controllerId,
           SharedPlayerManager.shared.automaticPipContext(for: controllerIdValue) != nil {
            // Reparent model: one shared controller. Don't toggle its flag or run
            // setAutomaticPiPEnabled on disposal (both views share it) — just unregister.
            SharedPlayerManager.shared.unregisterVideoPlayerView(viewId: viewId)
        } else if #available(iOS 14.2, *), let controllerIdValue = controllerId {
            let wasPrimaryView = SharedPlayerManager.shared.isPrimaryView(viewId, for: controllerIdValue)
            let wasAutoEnabled = SharedPlayerManager.shared.isControllerActiveForAutoPiP(controllerIdValue)
            let isPlaying = player?.rate ?? 0 > 0

            // Transfer automatic PiP if:
            // 1. This was the primary view AND auto PiP was enabled, OR
            // 2. The player is currently playing (should maintain auto PiP capability)
            if (wasPrimaryView && wasAutoEnabled) || isPlaying {
                print("🎬 View being disposed (primary: \(wasPrimaryView), autoEnabled: \(wasAutoEnabled), playing: \(isPlaying)) - transferring automatic PiP to another view")

                // Disable automatic PiP on this view before unregistering
                playerViewController.canStartPictureInPictureAutomaticallyFromInline = false

                // Unregister this view first so it won't be found
                SharedPlayerManager.shared.unregisterVideoPlayerView(viewId: viewId)

                // Re-enable automatic PiP - this will find and enable a different view
                // for the same controller (if any exists)
                SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: true)
                print("✅ Automatic PiP transferred to another view for controller \(controllerIdValue)")
            } else {
                // Normal unregister for non-primary views
                SharedPlayerManager.shared.unregisterVideoPlayerView(viewId: viewId)
            }
        } else {
            // Normal unregister for non-shared players
            SharedPlayerManager.shared.unregisterVideoPlayerView(viewId: viewId)
        }

        // Remove periodic time observer
        if let timeObserver = timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        // Only remove observers, don't dispose the player if it's shared
        // The shared player will be kept alive for reuse.
        //
        // Gate on the flags set by `addObservers(to:)` — without this,
        // secondary / shared-player views that never registered (player
        // had no `currentItem` at init AND never received a fresh
        // `loadUrl` through this view's method handler) would throw
        // `_removeObserver:forProperty:` here. Repro: floating-preview
        // view created for a track that's already playing on the inline
        // view, then disposed when the user skips tracks.
        if didRegisterPlayerItemObservers, let item = player?.currentItem {
            item.removeObserver(self, forKeyPath: "status")
            item.removeObserver(self, forKeyPath: "playbackBufferEmpty")
            item.removeObserver(self, forKeyPath: "playbackLikelyToKeepUp")
            item.removeObserver(self, forKeyPath: "presentationSize")
            didRegisterPlayerItemObservers = false
        }

        if didRegisterPlayerObservers {
            // Remove player observer for timeControlStatus
            player?.removeObserver(self, forKeyPath: "timeControlStatus")

            // Remove player observer for externalPlaybackActive
            player?.removeObserver(self, forKeyPath: "externalPlaybackActive")
            didRegisterPlayerObservers = false
        }

        // Remove route detector observer
        if #available(iOS 11.0, *) {
            routeDetector?.removeObserver(self, forKeyPath: "multipleRoutesDetected")
            routeDetector?.isRouteDetectionEnabled = false
            routeDetector = nil
        }

        NotificationCenter.default.removeObserver(self)
        methodChannel.setMethodCallHandler(nil)

        // Clean up DRM handler
        drmHandler?.cleanup()
        drmHandler = nil

        // Clear current media info from this view
        // BUT do NOT clear from SharedPlayerManager if PiP is active
        // This ensures media controls survive view disposal during PiP
        currentMediaInfo = nil
        if !isPipActiveNow {
            // Only clear from SharedPlayerManager if PiP is NOT active
            if let controllerIdValue = controllerId {
                // But first check if there are other views using this controller
                let otherViews = SharedPlayerManager.shared.findAllViewsForController(controllerIdValue)
                if otherViews.count <= 1 {
                    // This is the last view, safe to clear media info
                    print("🧹 Clearing media info from SharedPlayerManager (last view)")
                } else {
                    print("📱 Keeping media info in SharedPlayerManager (other views exist)")
                }
            }
        } else {
            print("📱 Keeping media info in SharedPlayerManager (PiP is active)")
        }

        // Emit current state to all remaining views for this controller
        // This ensures other views stay in sync when one view is disposed
        if let controllerIdValue = controllerId {
            let remainingViews = SharedPlayerManager.shared.findAllViewsForController(controllerIdValue)
            if !remainingViews.isEmpty {
                print("📤 Emitting current state to \(remainingViews.count) remaining view(s) for controller \(controllerIdValue)")
                for view in remainingViews {
                    // Skip the view being disposed (just in case it's still in the list)
                    if view.viewId != viewId {
                        view.emitCurrentState()
                    }
                }
            }
        }

        // Floating host shares the ONE controller — never nil its player. Just
        // detach its view if still parented here; it re-mounts on the next expand.
        if isDartFullscreenView {
            if playerViewController.viewIfLoaded?.superview === hostContainer {
                playerViewController.viewIfLoaded?.removeFromSuperview()
            }
        }

        // CRITICAL: For shared controllers, player and playerViewController are NOT disposed here
        // They're managed by SharedPlayerManager and persist across platform view disposal
        // This ensures PiP delegate callbacks continue to work when navigating between screens
        // Resources will be disposed when controller.dispose() is called from Dart
        if controllerId != nil && !isDartFullscreenView {
            print("✅ Platform view disposed but player AND view controller kept alive for controller ID: \(String(describing: controllerId))")
        } else if controllerId != nil && isDartFullscreenView {
            print("✅ Dart fullscreen platform view disposed - shared player/VC kept alive for controller ID: \(String(describing: controllerId))")
        } else {
            print("Platform view disposed for non-shared player")
        }
    }

    // MARK: - App Lifecycle Handling

    /// Re-arms auto-PIP at the last possible moment before backgrounding so
    /// AVKit reads the desired flag value at decision time — fixes the
    /// post-runtime-toggle window where the initial flag set is ignored.
    @objc func handleAppWillResignActive() {
        guard #available(iOS 14.2, *) else { return }
        // Don't override an explicit consumer disable.
        guard playerViewController.allowsPictureInPicturePlayback else { return }
        guard canStartPictureInPictureAutomatically else { return }

        guard let controllerIdValue = controllerId else {
            // Non-shared player: arm self.
            playerViewController.canStartPictureInPictureAutomaticallyFromInline = true
            return
        }

        if SharedPlayerManager.shared.automaticPipContext(for: controllerIdValue) != nil {
            // One shared controller, already in the on-screen host — just re-assert
            // its flag (never disable; both views share it).
            playerViewController.canStartPictureInPictureAutomaticallyFromInline = true
        } else {
            // No handoff context: legacy last-moment re-arm.
            playerViewController.canStartPictureInPictureAutomaticallyFromInline = true
            SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: true)
        }
    }

    /// Called when app enters background (including screen lock)
    /// Keeps audio session active to allow background playback
    @objc func handleAppDidEnterBackground() {
        print("📱 App entering background (screen lock) - maintaining audio session for view \(viewId)")

        // Store current playback rate before iOS might pause it
        let wasPlaying = player?.rate ?? 0 > 0

        // CRITICAL: Ensure audio session stays active when screen locks
        // This prevents iOS from pausing the video
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            print("   → Audio session kept active during background/lock")
        } catch {
            print("   ⚠️ Failed to keep audio session active: \(error.localizedDescription)")
        }

        // CRITICAL: iOS will pause AVPlayer when screen locks
        // We need to resume playback to continue audio in background
        if wasPlaying {
            // Small delay to ensure background transition completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self, let player = self.player else { return }

                // Resume playback at the desired speed
                player.play()
                player.rate = self.desiredPlaybackSpeed
                print("   → Resumed playback for background audio (rate: \(self.desiredPlaybackSpeed))")
            }
        } else {
            print("   → Player was not playing, not resuming")
        }
    }

    /// Called when app returns to foreground
    /// Restores Now Playing info which may have been cleared by the system
    @objc func handleAppWillEnterForeground() {
        print("📱 App entering foreground - restoring Now Playing info for view \(viewId)")

        // CRITICAL: Reactivate audio session first
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            print("   → Audio session reactivated")
        } catch {
            print("   ⚠️ Failed to reactivate audio session: \(error.localizedDescription)")
        }

        // Check if this view owns the remote commands
        guard RemoteCommandManager.shared.isOwner(viewId) else {
            print("   → View \(viewId) doesn't own remote commands, skipping restore")
            return
        }

        // Check if we have media info to restore
        var mediaInfo = currentMediaInfo

        // Fallback: Try to retrieve from SharedPlayerManager if not available locally
        if mediaInfo == nil, let controllerIdValue = controllerId {
            mediaInfo = SharedPlayerManager.shared.getMediaInfo(for: controllerIdValue)
            if mediaInfo != nil {
                print("   → Retrieved media info from SharedPlayerManager")
                currentMediaInfo = mediaInfo // Update local copy
            }
        }

        guard let mediaInfo = mediaInfo else {
            print("   ⚠️ No media info available to restore")
            return
        }

        // Delay slightly to ensure audio session is fully active
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            // Restore Now Playing info
            print("   → Restoring Now Playing info: \(mediaInfo["title"] ?? "Unknown")")
            self.setupNowPlayingInfo(mediaInfo: mediaInfo)

            // Also update the playback time to ensure controls show correct position
            self.updateNowPlayingPlaybackTime()
        }
    }

    /// Called when audio session is interrupted (e.g., phone call, other app's audio)
    @objc func handleAudioSessionInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        print("🔊 Audio session interruption: \(type == .began ? "began" : "ended")")

        switch type {
        case .began:
            print("   → Audio session interrupted, Now Playing info may be cleared")

        case .ended:
            // Check if we should resume playback
            var shouldResume = false
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    shouldResume = true
                    print("   → Should resume after interruption")
                }
            }

            // Reactivate audio session
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                print("   → Audio session reactivated")
            } catch {
                print("   ⚠️ Failed to reactivate audio session: \(error.localizedDescription)")
            }

            // Restore Now Playing info and resume playback if needed
            if RemoteCommandManager.shared.isOwner(viewId) {
                var mediaInfo = currentMediaInfo
                if mediaInfo == nil, let controllerIdValue = controllerId {
                    mediaInfo = SharedPlayerManager.shared.getMediaInfo(for: controllerIdValue)
                }

                if let mediaInfo = mediaInfo {
                    print("   → Restoring Now Playing info after interruption")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        guard let self = self else { return }
                        self.setupNowPlayingInfo(mediaInfo: mediaInfo)
                        self.updateNowPlayingPlaybackTime()

                        // Auto-resume playback if the system recommends it
                        if shouldResume {
                            print("   → Auto-resuming playback after interruption")
                            self.player?.play()
                        }
                    }
                }
            }

        @unknown default:
            break
        }
    }
}

// MARK: - Rotation Reparent Container

/// Edge-pinned container on the root view that holds the reparented player view.
/// Starts the child at its exact screen position (matching Flutter's layout)
/// and animates to fullscreen when iOS rotation changes the bounds.
/// `layoutSubviews` is called inside iOS's rotation animation block,
/// so the frame change is automatically animated.
private class RotationReparentContainer: UIView {
    private let initialRect: CGRect
    private let portraitRect: CGRect?
    private var previousBoundsSize: CGSize = .zero
    private var hasRotated = false

    init(childView: UIView, initialRect: CGRect, portraitRect: CGRect?) {
        self.initialRect = initialRect
        self.portraitRect = portraitRect
        super.init(frame: .zero)

        backgroundColor = .black
        clipsToBounds = true

        childView.removeFromSuperview()
        childView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(childView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let child = subviews.first else { return }

        if !hasRotated {
            if previousBoundsSize == .zero {
                child.frame = initialRect
            } else if bounds.size != previousBoundsSize {
                hasRotated = true
                let isRotatingToPortrait = bounds.height > bounds.width
                if isRotatingToPortrait, let pRect = portraitRect {
                    child.frame = pRect
                } else {
                    child.frame = bounds
                }
            }
        } else {
            let isPortrait = bounds.height > bounds.width
            if isPortrait, let pRect = portraitRect {
                child.frame = pRect
            } else {
                child.frame = bounds
            }
        }

        previousBoundsSize = bounds.size
    }
}
