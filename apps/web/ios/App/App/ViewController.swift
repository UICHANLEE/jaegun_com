import Capacitor
import UIKit

final class ViewController: CAPBridgeViewController {
    private let privacyShield = UIView()
    private var lifecycleObservers: [NSObjectProtocol] = []

    override func capacitorDidLoad() {
        super.capacitorDidLoad()
        bridge?.registerPluginInstance(JaegunSecureStoragePlugin())
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configurePrivacyShield()

        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.showPrivacyShield()
            }
        )
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.showPrivacyShield()
            }
        )
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.hidePrivacyShield()
                }
            }
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if UIApplication.shared.applicationState == .active {
            hidePrivacyShield()
        } else {
            showPrivacyShield()
        }
    }

    deinit {
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    }

    private func configurePrivacyShield() {
        privacyShield.translatesAutoresizingMaskIntoConstraints = false
        privacyShield.backgroundColor = UIColor(red: 31 / 255, green: 77 / 255, blue: 59 / 255, alpha: 1)
        privacyShield.isHidden = true
        privacyShield.accessibilityViewIsModal = true
        privacyShield.accessibilityIdentifier = "jaegun-privacy-shield"

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = "재건 공동체"
        title.textColor = .white
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.textAlignment = .center
        title.accessibilityTraits = .header
        privacyShield.addSubview(title)

        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: privacyShield.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: privacyShield.centerYAnchor)
        ])
    }

    private func showPrivacyShield() {
        guard let window = view.window else { return }
        if privacyShield.superview !== window {
            privacyShield.removeFromSuperview()
            window.addSubview(privacyShield)
            NSLayoutConstraint.activate([
                privacyShield.leadingAnchor.constraint(equalTo: window.leadingAnchor),
                privacyShield.trailingAnchor.constraint(equalTo: window.trailingAnchor),
                privacyShield.topAnchor.constraint(equalTo: window.topAnchor),
                privacyShield.bottomAnchor.constraint(equalTo: window.bottomAnchor)
            ])
        }
        privacyShield.isHidden = false
        window.bringSubviewToFront(privacyShield)
    }

    private func hidePrivacyShield() {
        privacyShield.isHidden = true
    }
}
