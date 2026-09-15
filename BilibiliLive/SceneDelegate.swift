import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        self.window = window
        AppDelegate.shared.connectWindow(window)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        AppDelegate.shared.sceneDidBecomeActive()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        if AppDelegate.shared.window === window {
            AppDelegate.shared.window = nil
        }
        window = nil
    }
}
