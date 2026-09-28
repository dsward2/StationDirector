import Foundation

/// Music.app over AppleScript. The first call triggers macOS's one-time
/// Automation consent prompt for whatever app runs this CLI (Terminal, …).
@MainActor
final class MusicPlayer {
    struct Track: Equatable {
        let id: String
        let name: String
        let artist: String
        let album: String
        let duration: Double
    }

    struct State {
        let playing: Bool
        let position: Double
        let track: Track?
        var remaining: Double { (track?.duration ?? 0) - position }
    }

    func state() throws -> State {
        let script = """
        tell application "Music"
            set ps to player state as text
            if ps is "stopped" then return ps
            set t to current track
            return ps & tab & (player position as text) & tab & (duration of t as text) & tab & ¬
                (persistent ID of t) & tab & (name of t) & tab & (artist of t) & tab & (album of t)
        end tell
        """
        let fields = try run(script).components(separatedBy: "\t")
        guard fields.count == 7 else { return State(playing: false, position: 0, track: nil) }
        let track = Track(id: fields[3], name: fields[4], artist: fields[5], album: fields[6],
                          duration: Double(fields[2]) ?? 0)
        return State(playing: fields[0] == "playing", position: Double(fields[1]) ?? 0, track: track)
    }

    /// Routes Music.app's output to exactly this AirPlay device.
    func selectAirPlayDevice(named name: String) throws {
        try run("""
        tell application "Music" to set current AirPlay devices to {AirPlay device "\(escape(name))"}
        """)
    }

    func play(playlist: String, shuffle: Bool) throws {
        try run("""
        tell application "Music"
            set shuffle enabled to \(shuffle)
            play playlist "\(escape(playlist))"
        end tell
        """)
    }

    func play() throws { try run(#"tell application "Music" to play"#) }
    func pause() throws { try run(#"tell application "Music" to pause"#) }

    /// Rewinds to the start of the current track and leaves Music paused.
    func rewindPaused() throws {
        try run("""
        tell application "Music"
            pause
            set player position to 0
        end tell
        """)
    }

    /// Moves to the next track and leaves Music paused at its start.
    func skipPaused() throws {
        try run("""
        tell application "Music"
            pause
            next track
            pause
            set player position to 0
        end tell
        """)
    }

    /// The upcoming track, when it's knowable: playlist order, shuffle off.
    func upNext() -> (title: String, artist: String)? {
        let script = """
        tell application "Music"
            if shuffle enabled then return ""
            set p to current playlist
            set i to index of current track
            if i ≥ (count of tracks of p) then return ""
            set t to track (i + 1) of p
            return (name of t) & tab & (artist of t)
        end tell
        """
        guard let fields = try? run(script).components(separatedBy: "\t"), fields.count == 2 else { return nil }
        return (fields[0], fields[1])
    }

    @discardableResult
    private func run(_ source: String) throws -> String {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw DirectorError("bad AppleScript") }
        let result = script.executeAndReturnError(&error)
        if let error {
            throw DirectorError("Music.app: \(error[NSAppleScript.errorMessage] ?? error)")
        }
        return result.stringValue ?? ""
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
