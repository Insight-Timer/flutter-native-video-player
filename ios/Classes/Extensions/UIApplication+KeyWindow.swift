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
