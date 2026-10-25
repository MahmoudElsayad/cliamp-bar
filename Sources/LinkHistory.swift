import Foundation

struct RecentLink: Codable, Equatable {
    let originalURL: String
    let title: String
    let artist: String?
    let lastOpenedAt: Date
    let trackCount: Int

    static func successful(originalURL: String, reply: RemoteReply<MutationResult>,
                           at date: Date = Date()) -> RecentLink? {
        let originalURL = originalURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = musicURL(originalURL), reply.ok, let job = reply.job, job.state == "succeeded",
              let tracks = job.result?.tracks, !tracks.isEmpty, let state = job.snapshot,
              ["playing", "paused"].contains(state.state), (state.stream_error ?? "").isEmpty,
              let path = state.track?.path, !path.isEmpty,
              tracks.contains(where: { $0.path == path }) else { return nil }
        let count = max(tracks.count, job.result?.total ?? 0)
        let fallback = url.host ?? originalURL
        let title = count == 1 ? nonempty(tracks[0].title) ?? fallback : "\(fallback) (\(count) tracks)"
        return RecentLink(originalURL: originalURL, title: title,
                          artist: count == 1 ? nonempty(tracks[0].artist) : nil,
                          lastOpenedAt: date, trackCount: count)
    }

    fileprivate static func musicURL(_ value: String) -> URL? {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

final class LinkHistory {
    static let key = "recentLinks.v1"
    static let limit = 50
    private(set) var entries: [RecentLink]
    private(set) var revision = 0
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([RecentLink].self, from: $0) } ?? []
        var seen = Set<String>()
        entries = Array(saved.filter {
            $0.originalURL == $0.originalURL.trimmingCharacters(in: .whitespacesAndNewlines)
                && RecentLink.musicURL($0.originalURL) != nil && !$0.title.isEmpty && $0.trackCount > 0
                && seen.insert($0.originalURL).inserted
        }.prefix(Self.limit))
    }

    func record(_ link: RecentLink) {
        precondition(Thread.isMainThread)
        entries.removeAll { $0.originalURL == link.originalURL }
        entries.insert(link, at: 0)
        entries = Array(entries.prefix(Self.limit))
        persist()
    }

    @discardableResult
    func remove(originalURL: String) -> Bool {
        precondition(Thread.isMainThread)
        let count = entries.count
        entries.removeAll { $0.originalURL == originalURL }
        guard entries.count != count else { return false }
        persist()
        return true
    }

    private func persist() {
        revision += 1
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) }
    }
}
