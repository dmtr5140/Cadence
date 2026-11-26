//
//  ServiceSessionStore.swift
//  Trop
//
//  One session per service: the token, the cookies that came with it, and the
//  account name once it is known. Kept apart from the YouTube session, which
//  has its own Keychain-backed store because InnerTube rotates it.
//

import Foundation

enum ServiceAccount: String, CaseIterable, Identifiable {
    case youtube
    case soundcloud
    case yandex
    case spotify
    case vk
    case appleMusic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .youtube: return "YouTube Music"
        case .soundcloud: return "SoundCloud"
        case .yandex: return "Яндекс Музыка"
        case .spotify: return "Spotify"
        case .vk: return "VK Музыка"
        case .appleMusic: return "Apple Music · эксперимент"
        }
    }

    /// The honest line under the title: what a login actually buys here.
    var detail: String {
        switch self {
        case .youtube: return "Своё воспроизведение. Google не пускает вход во встроенный браузер — импортируй cookies.txt из обычного."
        case .soundcloud: return "Своё воспроизведение публичных треков. Вход нужен для лайков и своих плейлистов."
        case .yandex: return "Каталог читается всегда, звук — только с Яндекс Плюсом."
        case .spotify: return "Каталог и импорт. Звука нет: Spotify не отдаёт поток никому, кроме своих плееров."
        case .vk: return "Каталог и свои списки. Сторонним приложениям VK закрыл audio API."
        case .appleMusic: return "ЭКСПЕРИМЕНТАЛЬНО. Полное воспроизведение через MusicKit, но играет системный плеер, а не наш."
        }
    }
}

struct ServiceSession: Codable, Equatable {
    var token: String?
    var cookies: [String: String] = [:]
    var accountName: String?
    var savedAt: Date = Date()

    var isConnected: Bool {
        if let token, !token.isEmpty { return true }
        return !cookies.isEmpty
    }
}

enum ServiceSessionStore {
    private static func key(_ account: ServiceAccount) -> String {
        "service.session.v1.\(account.rawValue)"
    }

    static func session(_ account: ServiceAccount) -> ServiceSession? {
        guard let data = UserDefaults.standard.data(forKey: key(account)) else { return nil }
        return try? JSONDecoder().decode(ServiceSession.self, from: data)
    }

    static func save(_ session: ServiceSession, for account: ServiceAccount) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        UserDefaults.standard.set(data, forKey: key(account))
    }

    static func clear(_ account: ServiceAccount) {
        UserDefaults.standard.removeObject(forKey: key(account))
    }

    /// Pushes a fresh session into the source that actually uses it, so the
    /// next search does not need the user to retype anything.
    static func apply(_ session: ServiceSession, to account: ServiceAccount) {
        switch account {
        case .yandex:
            if let token = session.token { YandexSource.setToken(token) }
        case .soundcloud:
            if let id = session.token { SoundCloudSource.setClientID(id) }
        default:
            break
        }
    }

    static func adopt(_ outcome: ServiceLoginOutcome, for account: ServiceAccount, accountName: String? = nil) {
        var session = ServiceSession()
        session.token = outcome.token
        session.cookies = outcome.cookies
        session.accountName = accountName
        save(session, for: account)
        apply(session, to: account)
    }
}
