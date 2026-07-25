// App.swift — DRIFT on iOS.
//
// The game is bundled, not fetched. `web/` ships inside the app and WKWebView loads it
// from file://, so there is no network in the play path at all — the game works on a
// plane, in a tunnel, with the radio off. That is also the difference Apple's guideline
// 4.2 turns on: a WKWebView pointing at a URL is a browser and gets rejected; a bundled
// offline game with native behaviour is an app.
//
// Native, not incidental: haptics on collision, the idle timer held off so the screen
// does not sleep mid-run, and the safe area respected so the notch never eats the field.

import UIKit
import WebKit

final class GameViewController: UIViewController, WKScriptMessageHandler {
    private var web: WKWebView!
    private let impact = UIImpactFeedbackGenerator(style: .rigid)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        // The game can ask for a real tap-feel: window.webkit.messageHandlers.haptic
        cfg.userContentController.add(self, name: "haptic")

        web = WKWebView(frame: .zero, configuration: cfg)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        guard let index = Bundle.main.url(forResource: "index", withExtension: "html",
                                          subdirectory: "web") else {
            // Fail loudly rather than showing a blank black screen that looks like a crash.
            let l = UILabel()
            l.text = "web/index.html missing from the bundle"
            l.textColor = .white
            l.numberOfLines = 0
            l.textAlignment = .center
            l.frame = view.bounds
            view.addSubview(l)
            return
        }
        web.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        impact.prepare()
    }

    // One run, no interruptions: the screen must not dim while a line is being steered.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard m.name == "haptic" else { return }
        impact.impactOccurred()
        impact.prepare()
    }

    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var prefersStatusBarHidden: Bool { true }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ app: UIApplication,
                     didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = GameViewController()
        w.makeKeyAndVisible()
        window = w
        return true
    }
}
