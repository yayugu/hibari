import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var router: AppRouter?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        if AppSettings.isRunningUnitTests {
            window.rootViewController = UIViewController()
        } else {
            let router = AppRouter(window: window)
            router.start()
            self.router = router
            connectionOptions.urlContexts.forEach { router.handle($0.url) }
        }
        window.overrideUserInterfaceStyle = AppSettings.appearance.userInterfaceStyle
        window.makeKeyAndVisible()
        self.window = window
        NotificationCenter.default.addObserver(self, selector: #selector(settingsDidChange),
                                               name: AppSettings.didChange, object: nil)
    }

    @objc private func settingsDidChange() {
        guard let window else { return }
        let style = AppSettings.appearance.userInterfaceStyle
        guard window.overrideUserInterfaceStyle != style else { return }
        UIView.transition(with: window, duration: 0.3, options: .transitionCrossDissolve) {
            window.overrideUserInterfaceStyle = style
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        URLContexts.forEach { router?.handle($0.url) }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        router?.didBecomeActive()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        router?.willResignActive()
    }
}
