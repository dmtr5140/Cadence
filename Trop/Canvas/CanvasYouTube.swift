//
//  CanvasYouTube.swift
//  Trop
//
//  A clip taken from a YouTube music video: the video the listener searched
//  for, cut to a window they chose. Stream links from the player expire after
//  a few hours, so a pick stores the video id and the window, never the URL,
//  and the link is resolved again whenever the clip is played.
//

import Foundation

enum CanvasYouTube {
    /// One search hit.
    struct Clip: Identifiable, Hashable {
        let id: String
        let title: String
        let channel: String
        let duration: String
        /// Length in seconds when the service sent one.
        let seconds: Double?
        let thumbnail: URL?
    }

    // MARK: - Search

    /// Music-video search. The service answers with deeply nested JSON, so the
    /// parser walks the tree instead of naming every wrapper: any node that
    /// carries a `videoId` and a title is a hit.
    static func search(_ query: String, limit: Int = 24) async -> [Clip] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        guard let json = try? await SearchService.shared.search(
            query: trimmed,
            params: YouTubeSearchFilter.video.rawValue
        ) else { return [] }

        var seen = Set<String>()
        var clips: [Clip] = []
        collect(json, clips: &clips, seen: &seen, limit: limit)
        return clips
    }

    private static func collect(_ node: Any, clips: inout [Clip], seen: inout Set<String>, limit: Int) {
        guard clips.count < limit else { return }

        if let dictionary = node as? [String: Any] {
            if let id = dictionary["videoId"] as? String,
               !id.isEmpty,
               !seen.contains(id),
               let title = titleText(dictionary) {
                seen.insert(id)
                let length = lengthText(dictionary)
                clips.append(Clip(
                    id: id,
                    title: title,
                    channel: channelText(dictionary),
                    duration: length.text,
                    seconds: length.seconds,
                    thumbnail: thumbnailURL(dictionary)
                ))
            }
            for value in dictionary.values { collect(value, clips: &clips, seen: &seen, limit: limit) }
            return
        }

        if let array = node as? [Any] {
            for value in array { collect(value, clips: &clips, seen: &seen, limit: limit) }
        }
    }

    // MARK: - Stream

    /// Resolved links live a few hours; the memo keeps scrolling cheap.
    private static let memo = LinkMemo()

    static func streamURL(for videoId: String) async -> URL? {
        guard !videoId.isEmpty else { return nil }
        if let cached = memo.value(for: videoId) { return cached }

        guard let stream = try? await StreamFallback.resolveVideo(
            .playback(videoId: videoId),
            using: InnerTubeClient.tropShared,
            providers: .tropLive
        ) else { return nil }

        let link: String
        switch stream {
        case .muxed(let url): link = url
        case .hls(let url): link = url
        case .split(let video, _, _): link = video
        }

        guard let url = URL(string: link) else { return nil }
        memo.store(url, for: videoId)
        return url
    }

    // MARK: - JSON helpers

    private static func text(_ node: Any?) -> String? {
        if let string = node as? String { return string.isEmpty ? nil : string }
        guard let dictionary = node as? [String: Any] else { return nil }
        if let simple = dictionary["simpleText"] as? String, !simple.isEmpty { return simple }
        if let content = dictionary["content"] as? String, !content.isEmpty { return content }
        if let runs = dictionary["runs"] as? [[String: Any]] {
            let joined = runs.compactMap { $0["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func titleText(_ dictionary: [String: Any]) -> String? {
        for key in ["title", "headline", "primaryText"] {
            if let value = text(dictionary[key]), !value.isEmpty { return value }
        }
        return nil
    }

    private static func channelText(_ dictionary: [String: Any]) -> String {
        for key in ["ownerText", "longBylineText", "shortBylineText", "subtitle", "secondaryText"] {
            if let value = text(dictionary[key]), !value.isEmpty { return value }
        }
        return ""
    }

    private static func lengthText(_ dictionary: [String: Any]) -> (text: String, seconds: Double?) {
        guard let raw = text(dictionary["lengthText"]) ?? text(dictionary["duration"]) else {
            return ("", nil)
        }
        return (raw, seconds(from: raw))
    }

    /// "3:45" or "1:02:11" into seconds.
    private static func seconds(from text: String) -> Double? {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private static func thumbnailURL(_ dictionary: [String: Any]) -> URL? {
        if let thumbnails = dictionary["thumbnails"] as? [[String: Any]] {
            for entry in thumbnails.reversed() {
                if let value = entry["url"] as? String, let url = URL(string: value) { return url }
            }
        }
        if let thumbnail = dictionary["thumbnail"] as? [String: Any],
           let thumbnails = thumbnail["thumbnails"] as? [[String: Any]] {
            for entry in thumbnails.reversed() {
                if let value = entry["url"] as? String, let url = URL(string: value) { return url }
            }
        }
        return nil
    }
}

// MARK: - Memo

/// Tiny TTL cache for resolved links. A class with a lock, not an actor, so the
/// backdrop can read it without an await hop inside its task.
private final class LinkMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: (url: URL, at: Date)] = [:]
    private let ttl: TimeInterval = 240

    func value(for key: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let hit = items[key], Date().timeIntervalSince(hit.at) < ttl else { return nil }
        return hit.url
    }

    func store(_ url: URL, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        items[key] = (url, Date())
    }
}
