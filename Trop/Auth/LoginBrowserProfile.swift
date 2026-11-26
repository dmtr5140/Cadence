//
// LoginBrowserProfile.swift
// Trop
//
// Google refuses its sign-in inside embedded webviews when the user agent looks
// like one. A full desktop Safari or Chrome UA usually passes, a bare WKWebView
// UA never does. No profile wins for everyone, so the profile is switchable and
// the login screen offers the next one instead of dead-ending.
//

import Foundation

enum LoginBrowserProfile: String, CaseIterable, Identifiable {
    case desktopSafari
    case desktopChrome
    case mobileSafari

    var id: String { rawValue }

    var title: String {
        switch self {
        case .desktopSafari: return "Safari, компьютер"
        case .desktopChrome: return "Chrome, компьютер"
        case .mobileSafari: return "Safari, iPhone"
        }
    }

    var userAgent: String {
        switch self {
        case .desktopSafari:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        case .desktopChrome:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
        case .mobileSafari:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
        }
    }

    private static let key = "login.browser.profile"

    static var current: LoginBrowserProfile {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let value = LoginBrowserProfile(rawValue: raw) else { return .desktopSafari }
            return value
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// The next profile, so a retry is never the same browser twice in a row.
    static func next(after profile: LoginBrowserProfile) -> LoginBrowserProfile {
        let all = LoginBrowserProfile.allCases
        guard let index = all.firstIndex(of: profile) else { return .desktopSafari }
        return all[(index + 1) % all.count]
    }

    /// Google's refusal lands on these paths. The path is more stable than the
    /// sentence, which is localised.
    static func isRejected(_ url: URL?) -> Bool {
        guard let path = url?.path.lowercased() else { return false }
        return path.contains("signin/rejected")
            || path.contains("signin/v2/rejected")
            || path.contains("deniedsigninrejected")
    }
}
