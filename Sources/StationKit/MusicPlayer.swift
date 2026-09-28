import Foundation

/// Where the station's music comes from: Music (or iTunes, on an older Mac)
/// on this Mac, or on another Mac on the local network via Remote Apple
/// Events (`eppc://`). A remote Mac needs Remote Application Scripting on
/// (System Settings › General › Sharing), its music app already open (remote
/// events can't launch it), and ControlBooth visible to it as an AirPlay
/// speaker — the station still takes the audio in over AirPlay.
public struct MusicTarget: Equatable, Sendable {
    /// Host name, Bonjour name or address; nil or empty = this Mac.
    public var host: String?
    /// Account on the remote Mac; nil = macOS asks.
    public var user: String?
    public var password: String?
    /// "Music", or "iTunes" on a Mac older than macOS Catalina.
    public var appName: String

    public static let local = MusicTarget(host: nil, user: nil, password: nil, appName: "Music")

    public init(host: String?, user: String?, password: String?, appName: String) {
        self.host = host
        self.user = user
        self.password = password
        self.appName = appName
    }

    public var isRemote: Bool { !(host ?? "").trimmingCharacters(in: .whitespaces).isEmpty }

    /// "Music on Studio-Mac.local", for messages.
    public var displayName: String {
        isRemote ? "\(appName) on \(host!)" : "\(appName) on this Mac"
    }

    /// The AppleScript application specifier, e.g.
    /// `application "Music" of machine "eppc://me:pw@Studio-Mac.local"`.
    var appleScriptApplication: String {
        let app = "application \"\(Self.escape(appName.isEmpty ? "Music" : appName))\""
        guard isRemote, let host else { return app }
        var url = "eppc://"
        if let user, !user.isEmpty {
            url += user.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? user
            if let password, !password.isEmpty {
                url += ":" + (password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password)
            }
            url += "@"
        }
        url += host.trimmingCharacters(in: .whitespaces)
        return "\(app) of machine \"\(Self.escape(url))\""
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Music.app (or iTunes) over AppleScript, on this Mac or a remote one (see
/// `MusicTarget`). Scripts are written against `application "Music"`; `run`
/// retargets them and compiles them with Music's terminology, which iTunes
/// shares. The first local call triggers macOS's one-time Automation prompt.
@MainActor
public final class MusicPlayer {
    public let target: MusicTarget

    public init(target: MusicTarget = .local) {
        self.target = target
    }

    /// Checks that the music app answers: returns e.g. "Music 1.5 on Studio-Mac.local".
    public func testConnection() throws -> String {
        let version = try run(#"tell application "Music" to return version"#)
        return "\(target.displayName), version \(version)"
    }

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

    /// When a remote Mac last answered on the Remote Apple Events port.
    private var remoteReachableAt: Date?

    @discardableResult
    private func run(_ source: String) throws -> String {
        // An unreachable Mac makes the Apple Event wait minutes to fail —
        // AppleScript's timeout doesn't cover connecting — so check the port
        // first (and again only every 30 s while it keeps answering).
        if target.isRemote, let host = target.host,
           remoteReachableAt.map({ Date().timeIntervalSince($0) > 30 }) ?? true {
            guard Self.canConnect(host: host.trimmingCharacters(in: .whitespaces), port: 3031, timeout: 3) else {
                remoteReachableAt = nil
                throw DirectorError("\(target.displayName): no answer from \(host) on the Remote Apple Events port (3031). "
                                    + "Check the host name, that the Mac is awake, and that System Settings › General › Sharing › "
                                    + "Remote Application Scripting is on there.")
            }
            remoteReachableAt = Date()
        }
        var error: NSDictionary?
        let script: NSAppleScript
        if let cached = compiled[source] {
            script = cached
        } else {
            // A remote application goes in a variable: written literally,
            // AppleScript contacts the other Mac at *compile* time (ignoring
            // `using terms from` and any timeout) and can hang for minutes.
            // Remote Macs also get a short reply timeout.
            let full: String
            if target.isRemote {
                full = """
                set targetApp to \(target.appleScriptApplication)
                using terms from application "Music"
                with timeout of 8 seconds
                \(source.replacingOccurrences(of: #"tell application "Music""#, with: "tell targetApp"))
                end timeout
                end using terms from
                """
            } else {
                full = """
                with timeout of 20 seconds
                \(source)
                end timeout
                """
            }
            guard let fresh = NSAppleScript(source: full) else { throw DirectorError("bad AppleScript") }
            fresh.compileAndReturnError(nil)
            if compiled.count < 32 { compiled[source] = fresh }
            script = fresh
        }
        let result = script.executeAndReturnError(&error)
        if let error {
            throw DirectorError(Self.describe(error, target: target))
        }
        return result.stringValue ?? ""
    }

    /// True if a TCP connection to `host:port` succeeds within `timeout`
    /// (name lookup included — it runs on a background thread).
    nonisolated static func canConnect(host: String, port: UInt16, timeout: TimeInterval) -> Bool {
        final class Box: @unchecked Sendable { var ok = false }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            defer { done.signal() }
            var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                                 ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var list: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, String(port), &hints, &list) == 0 else { return }
            defer { freeaddrinfo(list) }
            var entry = list
            while let info = entry?.pointee {
                let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
                if fd >= 0 {
                    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
                    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                    let connected = connect(fd, info.ai_addr, info.ai_addrlen) == 0
                    close(fd)
                    if connected { box.ok = true; return }
                }
                entry = info.ai_next
            }
        }
        return done.wait(timeout: .now() + timeout) == .success && box.ok
    }

    /// AppleScript errors in words, with the likely fix for the common ones.
    private static func describe(_ error: NSDictionary, target: MusicTarget) -> String {
        let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
        let message = (error[NSAppleScript.errorMessage] as? String) ?? "\(error)"
        let host = target.host ?? "the other Mac"
        let hint: String?
        switch number {
        case -600:
            hint = target.isRemote ? "\(target.appName) isn't open on \(host). Open it there; remote Apple Events can't launch it." : nil
        case -905, -906, -1708:
            hint = !target.isRemote ? nil : "Couldn't reach \(host) over Remote Apple Events. On that Mac, turn on System Settings › General › Sharing › Remote Application Scripting, and check the host name."
        case -1712:
            hint = "\(target.displayName) didn't answer in time."
        case -128:
            hint = target.isRemote ? "Sign-in to \(host) was cancelled. Enter the user name and password for an account on that Mac." : nil
        case -5000, -10004, -915:
            hint = target.isRemote ? "\(host) refused the sign-in. Check the user name and password." : nil
        case -1743:
            hint = "This app isn't allowed to control \(target.appName). Allow it in System Settings › Privacy & Security › Automation."
        default:
            hint = nil
        }
        return "\(target.displayName): \(message) (\(number))" + (hint.map { ". " + $0 } ?? "")
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
