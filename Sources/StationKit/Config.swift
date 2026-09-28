import Foundation

/// `station.json`. Every key is optional: the file is deep-merged over
/// `StationConfig.defaults`, so a config only needs the values it changes.
public struct StationConfig: Codable, Equatable, Sendable {
    public struct Ports: Codable, Equatable, Sendable {
        /// ControlBooth's AirPlay relay sends Music.app's decoded PCM here.
        public var musicIn: UInt16
        /// Announcer PCM (48 kHz / 2 ch S16LE) into the mixer's sidechain input.
        public var announcerIn: UInt16
        /// The station PCMMixer's control port (`gain 0 <g>` fades the music).
        public var mixerControl: UInt16
        /// AntennaHead's ControlBooth receiver.
        public var antennaHead: UInt16
        /// ControlBooth AirPlay relay's PCMUDPSender `--control-port`
        /// (`relay on` / `relay off`), fixed in AirPlayReceiverController.
        public var airPlayRelayControl: UInt16
    }

    /// Passed straight to `PCMMixer --duck-*` (start: AntennaHead's filler values).
    public struct Duck: Codable, Equatable, Sendable {
        public var threshold: Double
        public var attenuation: Double
        public var attackMs: Int
        public var releaseMs: Int
        public var holdMs: Int
    }

    public enum Segment: String, Codable, CaseIterable, Identifiable, Sendable {
        public var id: String { rawValue }

        /// Station ID, time, temperature, headlines. Music paused.
        case topOfHour
        /// Forecast. Music paused.
        case weather
        /// Station ID + time only, talked over the end of a song.
        case stationID
    }

    public struct ClockEvent: Codable, Equatable, Sendable {
        public var minute: Int
        public var segment: Segment

        public init(minute: Int, segment: Segment) {
            self.minute = minute
            self.segment = segment
        }
    }

    public var stationName: String
    public var slogan: String
    public var playlist: String
    public var shuffle: Bool
    /// The Mac whose Music (or iTunes) plays the station's music; nil or
    /// empty = this Mac. A host name, Bonjour name or address, reached with
    /// Remote Apple Events. See `MusicTarget`.
    public var musicHost: String?
    /// Account on `musicHost`. The password is never stored here: the host
    /// app passes it at runtime (ControlBooth keeps it in the Keychain).
    public var musicHostUser: String?
    /// "Music", or "iTunes" on an older Mac.
    public var musicApp: String?
    /// Music.app's name for ControlBooth's AirPlay receiver.
    public var airPlayDeviceName: String
    /// How far behind Music.app's `player position` the audio reaches the
    /// mixer (AirPlay buffering). Talk-over timing adds this.
    public var airPlayLatencySeconds: Double
    public var latitude: Double
    public var longitude: Double
    /// NWS requires a User-Agent with contact info.
    public var weatherUserAgent: String
    public var newsFeeds: [String]
    public var headlineCount: Int
    public var voice: String?
    public var speechRate: Double?
    /// Talk over the end of every Nth song (0 = never).
    public var talkOverEvery: Int
    /// Speech ends this long before the song's audio does.
    public var talkOverEndGapSeconds: Double
    /// Skip a talk-over whose clip is longer than this.
    public var maxTalkOverSeconds: Double
    /// A due clock segment waits for the current song to end, up to this
    /// long; after that the music is faded out for it.
    public var maxSegmentWaitSeconds: Double
    /// Write the announcer's lines with Apple's on-device model (falls back
    /// to templates when unavailable or when a line fails the fact check).
    public var useAI: Bool
    public var clock: [ClockEvent]
    public var ports: Ports
    public var duck: Duck
    public var helpersPath: String
    /// Overrides `helpersPath` for PCMSpeechSynth only (e.g. a PipelineHelpers
    /// build newer than the one bundled in AntennaHead).
    public var speechSynthPath: String?
    /// The source name AntennaHead shows ("ControlBooth: <name>").
    public var antennaHeadSourceName: String

    public static let defaults = StationConfig(
        stationName: "AntennaHead Radio",
        slogan: "your station, on your own terms",
        playlist: "Music",
        shuffle: true,
        musicHost: nil,
        musicHostUser: nil,
        musicApp: "Music",
        airPlayDeviceName: "ControlBooth",
        airPlayLatencySeconds: 2.0,
        latitude: 34.7465,
        longitude: -92.2896,
        weatherUserAgent: "AntennaHead-StationDirector (https://github.com/dsward2)",
        newsFeeds: [
            "NPR | https://feeds.npr.org/1001/rss.xml",
            "KARK | https://www.kark.com/feed/",
        ],
        headlineCount: 3,
        voice: "com.apple.voice.premium.en-US.Ava",
        speechRate: nil,
        talkOverEvery: 1,
        talkOverEndGapSeconds: 1.0,
        maxTalkOverSeconds: 12,
        maxSegmentWaitSeconds: 240,
        useAI: true,
        clock: [
            ClockEvent(minute: 0, segment: .topOfHour),
            ClockEvent(minute: 30, segment: .weather),
        ],
        ports: Ports(musicIn: 6031, announcerIn: 6032, mixerControl: 6033,
                     antennaHead: 6019, airPlayRelayControl: 6029),
        duck: Duck(threshold: 0.02, attenuation: 0.25, attackMs: 40, releaseMs: 400, holdMs: 250),
        helpersPath: "/Applications/AntennaHead.app/Contents/Helpers",
        speechSynthPath: nil,
        antennaHeadSourceName: "AntennaHead Radio"
    )

    public static func load(path: String?) throws -> StationConfig {
        guard let path else { return defaults }
        let data = try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        var config = try merged(json: data)
        // Relative paths are relative to the config file.
        let dir = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).deletingLastPathComponent()
        if let p = config.speechSynthPath, !p.hasPrefix("/"), !p.hasPrefix("~") {
            config.speechSynthPath = dir.appendingPathComponent(p).standardizedFileURL.path
        }
        return config
    }

    /// Decodes `json` deep-merged over `defaults`, so a partial or older
    /// settings object still loads (keys it lacks take their defaults).
    public static func merged(json data: Data) throws -> StationConfig {
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as! [String: Any]
        guard let user = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DirectorError("station settings: top level must be a JSON object")
        }
        return try JSONDecoder().decode(StationConfig.self,
                                        from: JSONSerialization.data(withJSONObject: deepMerge(base, user)))
    }

    private static func deepMerge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var out = base
        for (key, value) in over {
            if let b = base[key] as? [String: Any], let o = value as? [String: Any] {
                out[key] = deepMerge(b, o)
            } else {
                out[key] = value
            }
        }
        return out
    }

    public func musicTarget(password: String?) -> MusicTarget {
        MusicTarget(host: musicHost, user: musicHostUser, password: password,
                    appName: (musicApp ?? "").isEmpty ? "Music" : musicApp!)
    }

    public func helper(_ name: String) -> String {
        if name == "PCMSpeechSynth", let speechSynthPath { return (speechSynthPath as NSString).expandingTildeInPath }
        return (helpersPath as NSString).appendingPathComponent(name)
    }
}

public struct DirectorError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Where StationKit's log lines go. The default prints them to stderr with a
/// timestamp; ControlBooth routes them to its log window and the Radio tab.
public enum Log {
    nonisolated(unsafe) public static var handler: @Sendable (String) -> Void = { message in
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        FileHandle.standardError.write(Data("[\(f.string(from: Date()))] \(message)\n".utf8))
    }

    public static func info(_ message: String) { handler(message) }
}
