import Foundation

/// Music.app over AppleScript. The first call triggers macOS's one-time
/// Automation consent prompt for whatever app runs this CLI (Terminal, …).
@MainActor
public final class MusicPlayer {
    public init() {}

    /// Names of the user's playlists that have tracks, for a settings picker.
    public func playlistNames() -> [String] {
        let script = """
        tell application "Music"
            set out to {}
            repeat with p in user playlists
                if (count of tracks of p) > 0 then set end of out to name of p
            end repeat
            set AppleScript's text item delimiters to linefeed
            return out as text
        end tell
        """
        return ((try? run(script)) ?? "").split(separator: "\n").map(String.init)
    }

    /// Names of every AirPlay device Music.app can see.
    public func airPlayDeviceNames() -> [String] {
        let script = """
        tell application "Music"
            set out to {}
            repeat with d in AirPlay devices
                set end of out to name of d
            end repeat
            set AppleScript's text item delimiters to linefeed
            return out as text
        end tell
        """
        return ((try? run(script)) ?? "").split(separator: "\n").map(String.init)
    }

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
        let count = try run("tell application \"Music\" to return count of tracks of playlist \"\(escape(playlist))\"")
        guard (Int(count) ?? 0) > 0 else {
            throw DirectorError("playlist '\(playlist)' is empty or missing")
        }
        try run("""
        tell application "Music"
            set shuffle enabled to \(shuffle)
            play playlist "\(escape(playlist))"
        end tell
        """)
    }

    func play() throws { try run(#"tell application "Music" to play"#) }

    /// Plays on from a pause, or starts the playlist over if Music has
    /// stopped (a plain `play` does nothing with no current track).
    func resume(playlist: String, shuffle: Bool) throws {
        let state = try run(#"tell application "Music" to return player state as text"#)
        if state == "stopped" {
            try play(playlist: playlist, shuffle: shuffle)
        } else {
            try play()
        }
    }
    func pause() throws { try run(#"tell application "Music" to pause"#) }

    /// Seeks the playing track back to its start (Music keeps playing, so
    /// the AirPlay session stays up — see Director).
    func seekToStart() throws {
        try run(#"tell application "Music" to set player position to 0"#)
    }

    func nextTrack() throws { try run(#"tell application "Music" to next track"#) }

    /// Names of the currently selected AirPlay devices, one per line.
    func selectedAirPlayDevices() -> [String] {
        let script = """
        tell application "Music"
            set out to {}
            repeat with d in (current AirPlay devices)
                set end of out to name of d
            end repeat
            set AppleScript's text item delimiters to linefeed
            return out as text
        end tell
        """
        return ((try? run(script)) ?? "").split(separator: "\n").map(String.init)
    }

    func selectAirPlayDevices(named names: [String]) throws {
        let list = names.map { "AirPlay device \"\(escape($0))\"" }.joined(separator: ", ")
        try run("tell application \"Music\" to set current AirPlay devices to {\(list)}")
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

    /// Compiled scripts, by source: `state()` runs four times a second, and
    /// compiling is most of an NSAppleScript call's cost.
    private var compiled: [String: NSAppleScript] = [:]

    @discardableResult
    private func run(_ source: String) throws -> String {
        var error: NSDictionary?
        let script: NSAppleScript
        if let cached = compiled[source] {
            script = cached
        } else {
            guard let fresh = NSAppleScript(source: source) else { throw DirectorError("bad AppleScript") }
            fresh.compileAndReturnError(nil)
            if compiled.count < 32 { compiled[source] = fresh }
            script = fresh
        }
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
