//
//  LoginWebView.swift
//  Trop
//
//  Created by 686udjie on 28/06/2026.
//

@preconcurrency import SwiftUI
import SwiftyTube
import WebKit

// Presented as a sheet — launches Google OAuth in a full-screen WKWebView
struct LoginWebView: View {
    let model: LoginViewModel

    var body: some View {
        Presenter(model: model)
            .ignoresSafeArea()
    }
}

// Bridges the WKWebView into SwiftUI using a hosting controller
private struct Presenter: UIViewControllerRepresentable {
    typealias UIViewControllerType = WebLoginController

    let model: LoginViewModel

    func makeUIViewController(context: UIViewControllerRepresentableContext<Presenter>) -> WebLoginController {
        WebLoginController(model: model)
    }

    func updateUIViewController(_ vc: WebLoginController, context: UIViewControllerRepresentableContext<Presenter>) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {}
}

// Controller that hosts a WKWebView for the Google OAuth flow
final class WebLoginController: UIViewController {
    let model: LoginViewModel
    private var delegate: LoginNavigationDelegate?

    init(model: LoginViewModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let delegate = LoginNavigationDelegate(model: model)
        self.delegate = delegate
        delegate.presenter = self

        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        // Google serves a cookie-incomplete login flow to mobile user agents.
        webView.customUserAgent = LoginBrowserProfile.current.userAgent
        webView.navigationDelegate = delegate
        view = webView

        let url = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https://music.youtube.com")!
        webView.load(URLRequest(url: url))
    }
}

// Handles navigation and imports the session once Google lands on music.youtube.com
private final class LoginNavigationDelegate: NSObject, WKNavigationDelegate {
    let model: LoginViewModel
    private var didCaptureSession = false

    init(model: LoginViewModel) {
        self.model = model
    }

    /// Set by the controller so a refusal can be explained, not dead-ended.
    weak var presenter: UIViewController?

    /// Google answered "this browser or app may not be secure". Offer the next
    /// profile and reload; the same page in another browser often goes through.
    func promptAnotherBrowser(_ webView: WKWebView) {
        let next = LoginBrowserProfile.next(after: LoginBrowserProfile.current)
        Task { @MainActor [weak self, weak webView] in
            guard let self, let presenter = self.presenter, let webView else { return }
            let alert = UIAlertController(
                title: "Google не пускает этот браузер",
                message: "Страница «браузер или приложение может быть небезопасным». Попробуем ещё раз, притворившись другим браузером: \(next.title).",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Попробовать: \(next.title)", style: .default) { _ in
                LoginBrowserProfile.current = next
                webView.customUserAgent = next.userAgent
                if let url = webView.url {
                    webView.load(URLRequest(url: url))
                } else {
                    webView.reload()
                }
            })
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
            presenter.present(alert, animated: true)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if LoginBrowserProfile.isRejected(webView.url) {
            promptAnotherBrowser(webView)
            return
        }
        guard let url = webView.url, url.host?.contains("music.youtube.com") == true else {
            return
        }
        guard !didCaptureSession, model.canCaptureSession else { return }

        Log.login.debug("Redirected to \(url.host ?? "") — collecting cookies...")

        Task { @MainActor [weak self, weak webView] in
            guard let webView else { return }
            // The first snapshot after the redirect is incomplete; the harvest
            // polls until the rotating session tokens are present.
            let session = await LoginWebviewHarvest.collectSession(from: webView) { [weak self] in
                guard let self, !self.didCaptureSession, self.model.canCaptureSession else { return false }
                return true
            }
            guard let self, let (cookies, sapisid) = session else {
                Log.login.notice("  ❌ No complete session found — login may have failed")
                return
            }
            self.didCaptureSession = true

            // Read dataSyncId first, then save the whole session in one step so
            // the login survives a relaunch and InnerTube is signed in before
            // any view sees isLoggedIn.
            webView.evaluateJavaScript("window.yt?.config_?.DATASYNC_ID ?? ''") { result, error in
                let dataSyncId = (result as? String).flatMap { $0.isEmpty ? nil : $0 }
                if let error {
                    Log.login.error("  ⚠️ JS eval for dataSyncId failed: \(error.localizedDescription)")
                } else if dataSyncId == nil {
                    Log.login.notice("  ⚠️ dataSyncId not found in page context")
                }
                self.model.handleLogin(
                    cookies: cookies,
                    sapisid: sapisid,
                    visitorData: cookies["visitor_data"],
                    dataSyncId: dataSyncId
                )
            }
        }
    }
}
