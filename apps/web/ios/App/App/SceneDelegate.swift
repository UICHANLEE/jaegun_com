import UIKit
import Capacitor

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var launchLinkObserver: NSObjectProtocol?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        window = UIWindow(windowScene: windowScene)
        window?.rootViewController = ViewController()
        window?.makeKeyAndVisible()

        // Validate cold-launch links through the same boundary as hot deliveries.
        // The proxy's willConnect helper forwards connectionOptions unfiltered.
        NotificationCenter.default.post(name: .capacitorSceneWillConnect, object: scene)
        launchLinkObserver = NotificationCenter.default.addObserver(
            forName: .capacitorViewDidAppear, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if let observer = self.launchLinkObserver {
                NotificationCenter.default.removeObserver(observer)
                self.launchLinkObserver = nil
            }
            self.scene(scene, openURLContexts: connectionOptions.urlContexts)
            for activity in connectionOptions.userActivities {
                self.scene(scene, continue: activity)
            }
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        let allowed = Set(URLContexts.filter { isAllowedSocialCallback($0.url) })
        SceneDelegateProxy.shared.scene(scene, openURLContexts: allowed)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL,
              isAllowedSocialCallback(url) else { return }
        SceneDelegateProxy.shared.scene(scene, continue: userActivity)
    }

    deinit {
        if let observer = launchLinkObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func isAllowedSocialCallback(_ url: URL) -> Bool {
        guard url.absoluteString.count <= 4_096,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              components.host == "jaegun-com.vercel.app",
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.percentEncodedPath == "/auth/callback/social" else { return false }
        return url.absoluteString == "https://jaegun-com.vercel.app/auth/callback/social"
            || url.absoluteString.hasPrefix("https://jaegun-com.vercel.app/auth/callback/social?")
    }
}
