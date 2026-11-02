import UIKit

@MainActor final class OrbitMainTabController: OrbitTabBarController {
    func openRefreshSetup() {
        guard let navigation = destinations.last as? UINavigationController,
              let settings = navigation.viewControllers.first as? OrbitSettingsController else { return }
        destinationIndex = destinations.count - 1
        settings.openRefreshSetup()
    }
}
