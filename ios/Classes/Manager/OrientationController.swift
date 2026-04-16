import Flutter
import UIKit

/// Commits an iOS scene interface-orientation change while hiding the
/// default scene rotation animation (no visible top-left pivot/skew).
///
/// ## Why the animation is hard to suppress
///
/// `UIWindowScene.requestGeometryUpdate(...)` always animates. The rotation
/// animation is driven by the *window server* (backboardd), not by an
/// in-process `CAAnimation`, so standard suppression techniques like
/// `performWithoutAnimation` and `CATransaction.setDisableActions` cannot
/// prevent it. `CALayer.speed` on the key window's layer also cannot
/// suppress it because the window server drives the transform externally.
///
/// ## Hiding strategy (opaque native overlay)
///
/// Since the rotation animation cannot be suppressed, we **hide** it instead
/// by placing an opaque black `UIView` in the key window that covers all
/// content. The overlay is added synchronously *before* `requestGeometryUpdate`
/// so it is visible in the very first frame. Because the overlay is a solid
/// colour, the system's rotation animation on it is invisible (rotating a
/// uniform rectangle looks the same at every angle).
///
/// The Dart side is responsible for removing the overlay after the rotation
/// commits and the Flutter layout has settled, by calling
/// `removeOrientationOverlay` through the method channel.
///
/// ## Additional layers
///
/// 1. **Sync FlutterViewController's `_orientationPreferences`** — poke the
///    private ivar via KVC so the engine's
///    `supportedInterfaceOrientations` getter returns the new mask without
///    re-entering its own animated `setOrientationPreferences:` code path
///    (which would call `requestGeometryUpdate` *again*).
///
/// 2. **`performWithoutAnimation` + `CATransaction.setDisableActions`** —
///    standard suppression that prevents any in-process `CAAnimation` from
///    overlaying additional visual artefacts during the transition.
///
/// ## iOS version gating
///
/// - iOS 16+: uses `requestGeometryUpdate` + the overlay strategy above.
/// - iOS < 16: no-op — caller should fall back to
///   `SystemChrome.setPreferredOrientations`.
@objc public class OrientationController: NSObject {

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Overlay state
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// The opaque overlay that hides the system rotation animation.
    /// Stored as a static property so `removeOrientationOverlay` can find it.
    private static var rotationOverlay: UIView?

    /// Safety timer that removes the overlay if Dart never calls
    /// `removeOrientationOverlay` (e.g. because the method channel call was
    /// lost). 2 seconds is generous — the Dart side normally removes it
    /// within ~500 ms.
    private static var overlayTimeoutTimer: Timer?

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Public API
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Requests a scene-level orientation change to the given [mask], hiding
    /// the system rotation animation behind an opaque native overlay.
    ///
    /// Returns `true` when the native path handled the rotation (iOS 16+).
    /// Returns `false` on older iOS or when no active scene is found.
    @objc public static func setOrientations(mask: UIInterfaceOrientationMask) -> Bool {
        guard Thread.isMainThread else { return false }

        print("🧭 [OrientationController] setOrientations enter: mask=\(mask.rawValue)")

        guard #available(iOS 16.0, *) else {
            print("🧭 [OrientationController] iOS < 16 — falling back to SystemChrome")
            return false
        }

        return performOrientationChange(mask: mask)
    }

    /// Removes the opaque overlay that was added during the orientation
    /// change. The Dart side calls this once the Flutter layout has settled
    /// into the new orientation.
    @objc public static func removeOrientationOverlay() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { removeOrientationOverlay() }
            return
        }

        overlayTimeoutTimer?.invalidate()
        overlayTimeoutTimer = nil

        guard let overlay = rotationOverlay else {
            print("🧭 [OrientationController] removeOverlay — no overlay to remove")
            return
        }

        print("🧭 [OrientationController] removeOverlay — removing overlay")
        overlay.removeFromSuperview()
        rotationOverlay = nil
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Private: orientation change
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    @available(iOS 16.0, *)
    private static func performOrientationChange(mask: UIInterfaceOrientationMask) -> Bool {
        guard let scene = activeWindowScene() else {
            print("🧭 [OrientationController] No active window scene found — aborting")
            return false
        }

        let flutterVC = findFlutterViewController(in: scene)
        let targetVC = flutterVC ?? activeKeyWindow(in: scene)?.rootViewController
        let window = activeKeyWindow(in: scene)

        print(
            "🧭 [OrientationController] performOrientationChange: scene=\(scene), "
            + "flutterVC=\(String(describing: flutterVC)), targetVC=\(String(describing: targetVC))"
        )

        // ── Step 1: add opaque overlay ──────────────────────────────────
        //
        // Place a full-screen black UIView in the key window, above all
        // other content. Because it is a uniform solid colour the system's
        // rotation animation on it is invisible — rotating a solid black
        // rectangle looks the same at every angle.
        //
        // The overlay is added synchronously so it is visible in the very
        // first frame of the rotation animation.
        installOverlay(in: window)

        // ── Step 2: sync FlutterViewController's internal state ─────────
        //
        // Poke the private `_orientationPreferences` ivar so the engine's
        // `supportedInterfaceOrientations` getter returns the new mask
        // without re-entering its own animated `setOrientationPreferences:`
        // code path (which would call `requestGeometryUpdate` AGAIN).
        if let flutterVC = flutterVC {
            syncFlutterOrientationPreferences(on: flutterVC, mask: mask)
        }

        // ── Step 3: request geometry update ─────────────────────────────
        //
        // The standard `performWithoutAnimation` + `CATransaction` wrapper
        // suppresses in-process `CAAnimation`s. The opaque overlay above
        // hides whatever the window server does externally.
        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setAnimationDuration(0)

            let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
            scene.requestGeometryUpdate(prefs) { error in
                print("🧭 [OrientationController] requestGeometryUpdate failed: \(error)")
            }
            targetVC?.setNeedsUpdateOfSupportedInterfaceOrientations()

            CATransaction.commit()
        }

        print("🧭 [OrientationController] rotation dispatched, overlay installed")
        return true
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Private: overlay management
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private static func installOverlay(in window: UIWindow?) {
        guard let window = window else { return }

        // Remove any existing overlay from a previous (interrupted?) transition.
        rotationOverlay?.removeFromSuperview()
        overlayTimeoutTimer?.invalidate()

        let overlay = UIView(frame: window.bounds)
        overlay.backgroundColor = .black
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.isUserInteractionEnabled = false
        window.addSubview(overlay)
        rotationOverlay = overlay

        // Safety timeout: auto-remove the overlay after 2 s in case Dart
        // never calls removeOrientationOverlay.
        overlayTimeoutTimer = Timer.scheduledTimer(
            withTimeInterval: 2.0,
            repeats: false
        ) { _ in
            print("🧭 [OrientationController] overlay timeout — auto-removing")
            removeOrientationOverlay()
        }

        print("🧭 [OrientationController] overlay installed in window")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Private: FlutterViewController KVC
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private static func syncFlutterOrientationPreferences(
        on flutterVC: UIViewController,
        mask: UIInterfaceOrientationMask
    ) {
        let key = "orientationPreferences"
        let boxed = NSNumber(value: mask.rawValue)
        (flutterVC as NSObject).setValue(boxed, forKey: key)
        print(
            "🧭 [OrientationController] synced _orientationPreferences=\(mask.rawValue) "
            + "on \(flutterVC)"
        )
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Private: scene / window lookup
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    @available(iOS 13.0, *)
    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first
    }

    @available(iOS 13.0, *)
    private static func activeKeyWindow(in scene: UIWindowScene) -> UIWindow? {
        return scene.windows.first(where: { $0.isKeyWindow })
            ?? scene.windows.first
    }

    @available(iOS 13.0, *)
    private static func findFlutterViewController(
        in scene: UIWindowScene
    ) -> UIViewController? {
        guard let window = activeKeyWindow(in: scene) else { return nil }
        guard let root = window.rootViewController else { return nil }
        return search(in: root)
    }

    private static func search(in vc: UIViewController) -> UIViewController? {
        if vc is FlutterViewController { return vc }
        for child in vc.children {
            if let found = search(in: child) { return found }
        }
        if let presented = vc.presentedViewController {
            if let found = search(in: presented) { return found }
        }
        return nil
    }
}
