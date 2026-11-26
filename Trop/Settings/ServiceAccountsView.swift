//
//  ServiceAccountsView.swift
//  Trop
//
//  One row per service: is it signed in, what does signing in give you, and
//  what it never gives you. YouTube takes a cookies.txt file because Google
//  blocks its own OAuth in embedded browsers; the rest complete their round
//  trip inside the app.
//

import SwiftUI
import UniformTypeIdentifiers

struct ServiceAccountsView: View {
    @State private var active: ServiceAccount?
    @State private var showsCookiesImporter = false
    @State private var showsYouTubeLogin = false
    @State private var message: String?
    @State private var isImporting = false

    var body: some View {
        List {
            if let message {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(message.hasPrefix("Готово") ? Color.green : Color.orange)
                }
            }

            ForEach(ServiceAccount.allCases) { account in
                Section {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.title)
                                .font(.body.weight(.medium))
                            Text(status(for: account))
                                .font(.footnote)
                                .foregroundStyle(session(for: account)?.isConnected == true ? Color.green : Color.gray)
                        }
                        Spacer()
                        if session(for: account)?.isConnected == true {
                            Button("Выйти", role: .destructive) { signOut(account) }
                                .buttonStyle(.bordered)
                        } else if account != .appleMusic {
                            Button("Войти") { signIn(account) }
                                .buttonStyle(.borderedProminent)
                        }
                    }

                    if account == .youtube {
                        Button {
                            AccountState.shared.loginModel.isAddingAccount = true
                            showsYouTubeLogin = true
                        } label: {
                            Label("Войти в YouTube", systemImage: "person.crop.circle.badge.checkmark")
                        }
                        Button {
                            showsCookiesImporter = true
                        } label: {
                            Label("Импортировать cookies.txt", systemImage: "doc.badge.arrow.up")
                        }
                        .disabled(isImporting)
                    }

                    Text(account.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(account.title)
                }
            }

            Section {
                Text("Сначала попробуй «Войти в YouTube»: приложение подставляет десктопный Safari и, если Google всё равно отвечает «браузер небезопасен», предлагает другой браузер в один тап.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Если Google упирается во всех трёх профилях, остаётся cookies.txt. Его выгружают расширением «Get cookies.txt» в Chrome или Firefox на компьютере: на iPhone расширений с удобной выгрузкой cookie нет, так что это единственный путь, где ПК пока нужен.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Почему через файл")
            }
        }
        .sheet(isPresented: $showsYouTubeLogin) {
            NavigationStack {
                LoginWebView(model: AccountState.shared.loginModel)
                    .ignoresSafeArea()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Закрыть") { showsYouTubeLogin = false }
                        }
                    }
            }
        }
        .navigationTitle("Аккаунты сервисов")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showsCookiesImporter,
            allowedContentTypes: [.plainText, .data, .text],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { importCookies(from: url) }
            case .failure:
                message = "Файл не выбран"
            }
        }
        .sheet(item: $active) { account in
            ServiceLoginView(request: request(for: account)) { outcome in
                handle(outcome, for: account)
            }
        }
    }

    // MARK: - State

    private func session(for account: ServiceAccount) -> ServiceSession? {
        if account == .youtube {
            var session = ServiceSession()
            session.cookies = ["session": AccountState.shared.isLoggedIn ? "1" : ""]
            return AccountState.shared.isLoggedIn ? session : nil
        }
        return ServiceSessionStore.session(account)
    }

    private func status(for account: ServiceAccount) -> String {
        guard let session = session(for: account), session.isConnected else { return "Не подключён" }
        if let name = session.accountName, !name.isEmpty { return "Подключён · \(name)" }
        if account == .youtube, let name = AccountState.shared.accountName, !name.isEmpty {
            return "Подключён · \(name)"
        }
        return "Подключён"
    }

    private func signOut(_ account: ServiceAccount) {
        if account == .youtube {
            AccountState.shared.signOut()
            message = "YouTube Music: сессия очищена"
            return
        }
        ServiceSessionStore.clear(account)
        if account == .yandex { YandexSource.setToken("") }
        message = "\(account.title): сессия очищена"
    }

    private func signIn(_ account: ServiceAccount) {
        message = nil
        active = account
    }

    // MARK: - Login

    private func request(for account: ServiceAccount) -> ServiceLoginRequest {
        switch account {
        case .yandex:
            // Implicit flow of the Yandex Music client: the token lands in the
            // fragment, which the webview delegate catches before it vanishes.
            let url = URL(string: "https://oauth.yandex.ru/authorize?response_type=token&client_id=23cabbbdc6cd418abb4b39c32c41195d")!
            return ServiceLoginRequest(
                title: "Яндекс Музыка",
                startURL: url,
                tokenKeys: ["access_token"],
                cookieHosts: ["yandex"]
            )
        case .vk:
            let url = URL(string: "https://oauth.vk.com/authorize?client_id=2685278&scope=audio,offline&redirect_uri=https%3A%2F%2Foauth.vk.com%2Fblank.html&display=mobile&response_type=token&v=5.199")!
            return ServiceLoginRequest(
                title: "VK Музыка",
                startURL: url,
                tokenKeys: ["access_token"]
            )
        case .spotify:
            let url = URL(string: "https://accounts.spotify.com/en/login?continue=https%3A%2F%2Fopen.spotify.com%2F")!
            return ServiceLoginRequest(
                title: "Spotify",
                startURL: url,
                finishHosts: ["open.spotify.com"],
                cookieHosts: ["spotify.com"],
                userAgent: ServiceUserAgents.desktop
            )
        case .soundcloud:
            let url = URL(string: "https://soundcloud.com/signin")!
            return ServiceLoginRequest(
                title: "SoundCloud",
                startURL: url,
                finishHosts: ["soundcloud.com"],
                finishPaths: ["/", "/discover", "/feed", "/you/library"],
                cookieHosts: ["soundcloud.com"],
                userAgent: ServiceUserAgents.desktop
            )
        case .youtube, .appleMusic:
            let url = URL(string: "https://music.youtube.com")!
            return ServiceLoginRequest(title: account.title, startURL: url)
        }
    }

    private func handle(_ outcome: ServiceLoginOutcome, for account: ServiceAccount) {
        if account == .spotify, let cookie = outcome.cookies["sp_dc"], !cookie.isEmpty {
            var session = ServiceSession()
            session.token = nil
            session.cookies = ["sp_dc": cookie]
            ServiceSessionStore.save(session, for: account)
            message = "Готово: Spotify подключён"
            return
        }
        if account == .soundcloud, !outcome.cookies.isEmpty {
            var session = ServiceSession()
            session.cookies = outcome.cookies
            if let id = outcome.cookies["client_id"] { session.token = id }
            ServiceSessionStore.save(session, for: account)
            message = "Готово: SoundCloud подключён"
            return
        }
        guard outcome.token != nil || !outcome.cookies.isEmpty else {
            message = "\(account.title): вход не завершён"
            return
        }
        ServiceSessionStore.adopt(outcome, for: account)
        message = "Готово: \(account.title) подключён"
    }

    // MARK: - YouTube cookies

    private func importCookies(from url: URL) {
        isImporting = true
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            isImporting = false
        }

        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            message = "Не удалось прочитать файл"
            return
        }
        let markers = CookiesFile.parse(
            text,
            domains: ["youtube.com", "google.com", "googleusercontent.com", "googlevideo.com"]
        )
        guard let session = CookiesFile.youTubeSession(from: markers) else {
            message = "В файле нет SAPISID — выгрузи cookies именно с youtube.com, будучи залогиненным"
            return
        }

        Task { @MainActor in
            await AccountState.shared.importCookies(session.cookies)
            message = AccountState.shared.isLoggedIn
                ? "Готово: YouTube Music подключён"
                : "Cookies прочитаны, но сессия не подтвердилась — попробуй выгрузить файл заново"
        }
    }
}

enum ServiceUserAgents {
    /// Desktop Safari: Spotify and SoundCloud both serve the full web player
    /// (and its cookie) only to a desktop agent.
    static let desktop = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
}
