//
//  CookiesFileImport.swift
//  Trop
//
//  A cookies.txt exported from a desktop browser is the only login path Google
//  allows for a third-party client: its OAuth refuses embedded webviews. This
//  parser reads the Netscape format that every cookie extension writes.
//

import Foundation

enum CookiesFile {
    /// Netscape cookie file -> name: value, filtered to one site family.
    /// `#HttpOnly_` lines are real cookies, not comments.
    static func parse(_ text: String, domains: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#HttpOnly_") {
                line = String(line.dropFirst("#HttpOnly_".count))
            } else if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7 else { continue }

            let domain = fields[0]
            guard domains.contains(where: { domain.contains($0) }) else { continue }

            let name = fields[5]
            let value = fields[6]
            guard !name.isEmpty else { continue }
            out[name] = value
        }
        return out
    }

    /// The handful of cookies InnerTube needs to consider a session signed in.
    static func youTubeSession(from markers: [String: String]) -> (cookies: [String: String], sapisid: String)? {
        let keychain = ["SAPISID", "__Secure-3PAPISID", "__Secure-1PAPISID"]
        guard let sapisid = keychain.compactMap({ markers[$0] }).first(where: { !$0.isEmpty }) else {
            return nil
        }
        var cookies = markers
        cookies["SAPISID"] = sapisid
        return (cookies, sapisid)
    }
}
