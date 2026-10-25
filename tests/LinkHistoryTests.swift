import Foundation
import Darwin

private struct URLJobFixture: Decodable {
    let originalURL: String
    let reply: RemoteReply<MutationResult>
    let remember: Bool
}

private func linkReply(state: String = "playing", jobState: String = "succeeded", path: String = "resolved-audio",
                       tracks: [[String: Any]]? = [["title": "Returned title", "artist": "Returned artist", "path": "resolved-audio"]],
                       total: Int? = nil, error: String? = nil, actual: Bool = true) throws -> [String: Any] {
    var snapshot: [String: Any] = ["revision": 2, "playlist_revision": 2, "state": state,
                                   "logical_track": ["path": path, "title": "Logical title"]]
    if actual { snapshot["track"] = ["path": path, "title": "Unrelated snapshot title"] }
    if let error { snapshot["stream_error"] = error }
    var result: [String: Any] = [:]
    if let tracks { result["tracks"] = tracks }
    if let total { result["total"] = total }
    return ["ok": true, "job": ["state": jobState, "result": result, "snapshot": snapshot]]
}

private func extract(_ value: [String: Any], url: String = "https://Example.com/Music?token=A#Part") throws -> RecentLink? {
    let reply = try JSONDecoder().decode(RemoteReply<MutationResult>.self,
                                        from: JSONSerialization.data(withJSONObject: value))
    return RecentLink.successful(originalURL: url, reply: reply, at: Date(timeIntervalSince1970: 100))
}

func linkHistoryTests() throws {
    let name = "io.cliampbar.history-tests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let fixtures = try JSONDecoder().decode([URLJobFixture].self, from: Data(contentsOf: URL(fileURLWithPath: "tests/Fixtures/url-jobs.json")))
    for fixture in fixtures {
        let value = RecentLink.successful(originalURL: fixture.originalURL, reply: fixture.reply)
        try expect((value != nil) == fixture.remember, "Real Cliamp URL job proof for \(fixture.originalURL)")
    }
    let first = try extract(linkReply(), url: " \nhttps://Example.com/Music?token=A#Part \n")!
    try expect(first.originalURL == "https://Example.com/Music?token=A#Part" && first.title == "Returned title"
               && first.artist == "Returned artist" && first.trackCount == 1,
               "History preserves the trimmed original URL and uses returned metadata instead of the snapshot")
    try expect(try extract(linkReply(state: "paused")) != nil, "A proven paused track is a successful load")
    for value in [try linkReply(state: "stopped"), try linkReply(state: "loading"), try linkReply(actual: false),
                  try linkReply(path: "unrelated"), try linkReply(tracks: []), try linkReply(tracks: nil),
                  try linkReply(error: "Stream failed"), try linkReply(jobState: "failed"), try linkReply(jobState: "timed_out")] {
        try expect(try extract(value) == nil, "Unproven or failed playback cannot enter history")
    }
    try expect(try extract(linkReply(), url: "file:///music.wav") == nil, "History rejects a nonmusic URL scheme")
    try expect(try extract(linkReply(error: "")) != nil, "An empty stream error permits proven playback")
    let multiple = try extract(linkReply(tracks: [["path": "first", "title": "First song"], ["path": "resolved-audio"]], total: 2))!
    try expect(multiple.title == "Example.com (2 tracks)" && multiple.artist == nil && multiple.trackCount == 2,
               "A playlist uses its original domain and returned count instead of an arbitrary song title")
    let fallback = try extract(linkReply(tracks: [["path": "resolved-audio", "title": "  "]]))!
    try expect(fallback.title == "Example.com", "Missing titles fall back to the original domain")

    let history = LinkHistory(defaults: defaults)
    try expect(history.entries.isEmpty, "A fresh isolated history starts empty")
    history.record(first)
    history.record(multiple)
    try expect(history.entries.count == 1 && history.entries[0] == multiple && history.revision == 2,
               "Repeated exact URLs replace metadata and advance list identity without changing the count")
    let distinct = RecentLink(originalURL: "https://example.com/Music?token=A#Part", title: "Distinct case", artist: nil,
                              lastOpenedAt: Date(timeIntervalSince1970: 101), trackCount: 1)
    history.record(distinct)
    try expect(history.entries.map(\.originalURL) == [distinct.originalURL, first.originalURL], "URL case is part of the exact deduplication key")
    history.record(first)
    try expect(history.entries.map(\.originalURL) == [first.originalURL, distinct.originalURL], "Successful replay moves the original URL to the front")
    try expect(LinkHistory(defaults: defaults).entries == history.entries, "A new history instance restores all metadata and order")
    try expect(history.remove(originalURL: first.originalURL) && !history.remove(originalURL: first.originalURL), "Removal reports only a real change")
    try expect(LinkHistory(defaults: defaults).entries == [distinct], "Removal persists without a player connection")
    for index in 0..<55 {
        history.record(RecentLink(originalURL: "https://example.com/\(index)?q=A#part", title: "Song \(index)", artist: nil,
                                  lastOpenedAt: Date(timeIntervalSince1970: Double(index)), trackCount: 1))
    }
    try expect(history.entries.count == 50 && history.entries.first?.title == "Song 54" && history.entries.last?.title == "Song 5",
               "History keeps exactly the 50 most recent successful URLs")
    try expect(LinkHistory(defaults: defaults).entries == history.entries, "The bounded order persists across relaunch")
    var malformed = history.entries
    malformed.insert(RecentLink(originalURL: "javascript:bad", title: "Bad", artist: nil, lastOpenedAt: Date(), trackCount: 1), at: 0)
    malformed += history.entries
    defaults.set(try JSONEncoder().encode(malformed), forKey: LinkHistory.key)
    try expect(LinkHistory(defaults: defaults).entries == history.entries, "Persisted input is bounded, deduplicated, and limited to music URLs")
    defaults.set(Data("broken JSON".utf8), forKey: LinkHistory.key)
    try expect(LinkHistory(defaults: defaults).entries.isEmpty, "Corrupt persisted data is nonfatal")
    defaults.set("wrong type", forKey: LinkHistory.key)
    try expect(LinkHistory(defaults: defaults).entries.isEmpty, "An unexpected defaults type is nonfatal")
    print("PASS: real URL job snapshots, strict playback proof, metadata, exact URL keys, MRU, cap, persistence, removal, corrupt input")
}

func linkStoreTests() throws {
    let fixture = try FakeRuntimePlayer()
    let name = "io.cliampbar.link-store-tests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    let previous = ProcessInfo.processInfo.environment["CLIAMP_BINARY"]
    setenv("CLIAMP_BINARY", fixture.executable.path, 1)
    defer {
        defaults.removePersistentDomain(forName: name)
        if let previous { setenv("CLIAMP_BINARY", previous, 1) } else { unsetenv("CLIAMP_BINARY") }
    }
    let store = PlayerStore(runtime: RuntimeStateSession(retryDelay: 0.02, maximumRetryDelay: 0.04), defaults: defaults)
    defer { store.shutdown() }
    let url = "https://Example.com/Music?token=A#Part"
    try expect(!store.perform(.openURL(url)) && store.recentLinks.isEmpty, "Unavailable URL commands do not change history")
    store.connect()
    try waitUntil("The fake player connects for URL commands") {
        if case .ready = store.connection { return !store.busy }
        return false
    }
    try fixture.write("url-reply.json", linkReply())
    try expect(store.perform(.openURL(url)), "A supported URL command enters the existing serial worker")
    try expect(!store.perform(.openURL("https://example.com/rejected")), "A busy URL command is rejected")
    try waitUntil("A proven load records history") { !store.busy && store.recentLinks.count == 1 }
    try expect(store.snapshot?.revision == 10 && store.recentLinks.first?.title == "Returned title",
               "An older command snapshot records its own metadata without replacing newer global state")
    let original = store.recentLinks
    for (index, response) in [try linkReply(state: "stopped", actual: false), try linkReply(jobState: "failed"),
                             try linkReply(jobState: "timed_out"), try linkReply(path: "unrelated")].enumerated() {
        try fixture.write("url-reply.json", response)
        try expect(store.perform(.openURL(url)), "A replay is attempted once")
        try waitUntil("A failed replay completes") { !store.busy }
        try expect(store.recentLinks == original, "Failed and timed-out replay leaves metadata, order, and timestamp unchanged")
        if index == 0 || index == 3 {
            try expect(store.message == "Cliamp has not confirmed playback, so this link was not saved.",
                       "A completed job without playback proof explains why its link was not saved")
        }
    }
    try fixture.write("url-error.json", "transport failed")
    try expect(store.perform(.openURL("https://example.com/failed")), "A transport failure is attempted once")
    try waitUntil("The transport error completes") { !store.busy }
    try expect(store.recentLinks == original && store.message == "transport failed", "A transport error cannot add a history entry")
    try fixture.write("url-error.json", false)
    try fixture.write("url-reply.json", linkReply())
    let second = "https://example.com/second"
    try expect(store.perform(.openURL(second)), "A second successful URL is admitted")
    try waitUntil("The second URL becomes most recent") { !store.busy && store.recentLinks.count == 2 }
    try expect(store.recentLinks.map(\.originalURL) == [second, url], "Successful URLs retain exact originals in most recent order")
    try expect(store.perform(.openURL(url)), "A successful replay uses the saved original URL")
    try waitUntil("Successful replay updates order") { !store.busy && store.recentLinks.first?.originalURL == url }
    try expect(store.recentLinks.count == 2 && store.recentLinks[0].lastOpenedAt > original[0].lastOpenedAt,
               "Successful replay updates the timestamp without creating a duplicate")

    let beforeStale = store.recentLinks
    try fixture.write("command-delay.json", 0.6)
    let staleURL = "https://example.com/stale"
    try expect(store.perform(.openURL(staleURL)), "An in-flight URL starts before connection loss")
    try waitUntil("The URL process captures its old-epoch reply") { !fixture.urlCalls(staleURL, kind: "captured").isEmpty }
    var disconnected = false
    store.onChange = { if case .unavailable = store.connection { disconnected = true } }
    let pid = (fixture.calls(["remote", "events", "runtime.state"]).last!["pid"] as! NSNumber).int32Value
    kill(pid, SIGTERM)
    try waitUntil("The old runtime stream disconnects") { disconnected }
    store.showMessage("Current connection notice")
    try waitUntil("The stale URL completion drains") { !store.busy }
    try expect(store.message == "Current connection notice", "A stale URL completion cannot replace a current diagnostic")
    try expect(store.recentLinks == beforeStale, "An old-epoch successful reply cannot add or reorder history")
    try waitUntil("The stream reconnects without replay") { if case .ready = store.connection { return true }; return false }
    try expect(fixture.urlCalls(staleURL).count == 1 && LinkHistory(defaults: defaults).entries == beforeStale,
               "Reconnect preserves persisted history and never retries the URL")
    store.removeRecentLink(url)
    try expect(store.recentLinks.map(\.originalURL) == [second], "The store removes a history entry independently of playback")
    try fixture.write("command-delay.json", 0.03)
    try expect(store.perform(.openURL("https://example.com/shutdown")), "A final URL begins before shutdown")
    store.shutdown()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    try expect(LinkHistory(defaults: defaults).entries.map(\.originalURL) == [second], "A completion from a discarded client cannot persist history")
    print("PASS: URL command admission, exact replay, busy rejection, failed jobs, timeout, transport error, old revision, stale epoch, reconnect, shutdown")
}
