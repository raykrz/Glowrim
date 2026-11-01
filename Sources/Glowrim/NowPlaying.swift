import AppKit

/// Watches Spotify and Apple Music for track changes and fetches the current album art.
@MainActor
final class NowPlayingWatcher: NSObject {
    var onArtwork: ((NSImage) -> Void)?
    private var lastKey = ""
    private var pollTimer: Timer?

    override init() {
        super.init()
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(playerChanged),
                        name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"), object: nil)
        dnc.addObserver(self, selector: #selector(playerChanged),
                        name: NSNotification.Name("com.apple.Music.playerInfo"), object: nil)
        // Safety net in case a notification is missed.
        let t = Timer(timeInterval: 10, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    @objc private func playerChanged() {
        // Give the player a moment to update its track info.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated { self.refresh() }
        }
    }

    @objc func refresh() {
        if isRunning("com.spotify.client"),
           run(#"tell application "Spotify" to player state as string"#) == "playing" {
            let key = "spotify:" + (run(#"tell application "Spotify" to id of current track"#) ?? "")
            guard key != lastKey else { return }
            lastKey = key
            if let s = run(#"tell application "Spotify" to artwork url of current track"#), let url = URL(string: s) {
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    guard let data, let image = NSImage(data: data) else { return }
                    Task { @MainActor [weak self] in self?.onArtwork?(image) }
                }.resume()
            }
            return
        }

        if isRunning("com.apple.Music"),
           run(#"tell application "Music" to player state as string"#) == "playing" {
            let key = "music:" + (run(#"tell application "Music" to (persistent ID of current track) as string"#) ?? "")
            guard key != lastKey else { return }
            lastKey = key
            if let desc = runDescriptor(#"tell application "Music" to get raw data of artwork 1 of current track"#),
               let image = NSImage(data: desc.data) {
                onArtwork?(image)
            }
        }
    }

    // Only talk to players that are already open, so we never launch them by accident.
    private func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private func runDescriptor(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    private func run(_ source: String) -> String? {
        runDescriptor(source)?.stringValue
    }
}
