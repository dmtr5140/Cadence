//
//  ServiceLogin.swift
//  Trop
//
//  One webview login for every service that hands out a token or a session
//  cookie. Google refuses its own OAuth inside embedded browsers, but Yandex,
//  VK, Spotify and SoundCloud all complete their round trip here, so the user
//  never leaves the app and never copies anything by hand.
//

import SwiftUI
import WebKit

/// What to load, when to call it done, and where to look for the result.
struct ServiceLoginRequest {
    let title: String
    let startURL: URL
    /// Hosts that mean the round trip is over. Empty means "any host".
    var finishHosts: [String] = []
    /// Paths that mean the same; used where the host alone is not enough.
    var finishPaths: [String] = []
    /// Keys to look for in the URL fragment or query (implicit OAuth).
    var tokenKeys: [String] = []
    /// When not empty, cookies from these domains are collected as well.
    var cookieHosts: [String] = []
    var userAgent: String?
}

struct ServiceLoginOutcome {
    var token: String?
    var cookies: [String: String] = [:]
}

struct ServiceLoginView: View {
    let request: ServiceLoginRequest
    let onFinish: (ServiceLoginOutcome) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ServiceLoginWeb(request: request) { outcome in
                onFinish(outcome)
                dismiss()
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
    }
}

private struct ServiceLoginWeb: UIViewControllerRepresentable {
    let request: ServiceLoginRequest
    let onFinish: (ServiceLoginOutcome) -> Void

    func makeUIViewController(context: Context) -> ServiceLoginController {
        ServiceLoginController(request: request, onFinish: onFinish)
    }

    func updateUIViewController(_ controller: ServiceLoginController, context: Context) {}
}

final class ServiceLoginController: UIViewController {
    private let request: ServiceLoginRequest
    private let onFinish: (ServiceLoginOutcome) -> Void
    private var delegate: ServiceLoginDelegate?
    private var finished = false

    init(request: ServiceLoginRequest, onFinish: @escaping (ServiceLoginOutcome) -> Void) {
        self.request = request
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        let delegate = ServiceLoginDelegate(request: request) { [weak self] outcome in
            self?.finish(outcome)
        }
        self.delegate = delegate
        webView.navigationDelegate = delegate
        if let agent = request.userAgent { webView.customUserAgent = agent }

        view = webView
        webView.load(URLRequest(url: request.startURL))
    }

    private func finish(_ outcome: ServiceLoginOutcome) {
        guard !finished else { return }
        finished = true
        onFinish(outcome)
    }
}

private final class ServiceLoginDelegate: NSObject, WKNavigationDelegate {
    private let request: ServiceLoginRequest
    private let onFinish: (ServiceLoginOutcome) -> Void
    private var isHarvesting = false

    init(request: ServiceLoginRequest, onFinish: @escaping (ServiceLoginOutcome) -> Void) {
        self.request = request
        self.onFinish = onFinish
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        // Implicit OAuth answers in the fragment, which never reaches didFinish
        // as a document we could inspect — catch it on the way.
        if let token = token(in: url) {
            decisionHandler(.cancel)
            harvest(webView: webView, token: token)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url, isFinishURL(url) else { return }
        harvest(webView: webView, token: token(in: url))
    }

    private func isFinishURL(_ url: URL) -> Bool {
        let hostMatches = request.finishHosts.isEmpty
            || request.finishHosts.contains { url.host?.contains($0) == true }
        let pathMatches = request.finishPaths.isEmpty || request.finishPaths.contains(url.path)
        return hostMatches && pathMatches
    }

    private func token(in url: URL) -> String? {
        guard !request.tokenKeys.isEmpty else { return nil }
        let raw = url.absoluteString
        guard let hashIndex = raw.firstIndex(of: "#") else { return nil }
        let fragment = String(raw[raw.index(after: hashIndex)...])
        for pair in fragment.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            guard request.tokenKeys.contains(key) else { continue }
            let value = String(parts[1])
            return value.isEmpty ? nil : value.removingPercentEncoding ?? value
        }
        return nil
    }

    private func harvest(webView: WKWebView, token: String?) {
        guard !isHarvesting else { return }
        isHarvesting = true

        let deliver: ([String: String]) -> Void = { [weak self] cookies in
            guard let self else { return }
            var outcome = ServiceLoginOutcome()
            outcome.token = token
            outcome.cookies = cookies
            DispatchQueue.main.async { self.onFinish(outcome) }
        }

        guard !request.cookieHosts.isEmpty else {
            deliver([:])
            return
        }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            var collected: [String: String] = [:]
            for cookie in cookies where self.request.cookieHosts.contains(where: { cookie.domain.contains($0) }) {
                collected[cookie.name] = cookie.value
            }
            deliver(collected)
        }
    }
}
