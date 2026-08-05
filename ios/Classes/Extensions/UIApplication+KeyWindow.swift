import UIKit

extension UIApplication {

    /// Scene-aware replacement for the deprecated `UIApplication.keyWindow`.
    /// Works with both the UIScene-based lifecycle (iOS 13+) and the classic
    /// AppDelegate-based lifecycle.
    var activeKeyWindow: UIWindow? {
        if #available(iOS 13.0, *) {
            return connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
        }
        return windows.first { $0.isKeyWindow }
    }
}

extension UIView {

    /// Nearest view controller up the responder chain, or the key window's root as a
    /// fallback while this view is not yet in a VC-owned hierarchy.
    var parentViewController: UIViewController? {
        var responder: UIResponder? = next
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return UIApplication.shared.activeKeyWindow?.rootViewController
    }
}
