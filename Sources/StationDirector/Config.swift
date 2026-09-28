import Foundation

/// `station.json`. Every key is optional: the file is deep-merged over
/// `StationConfig.defaults`, so a config only needs the values it changes.
struct StationConfig: Codable {
    struct Ports: Codable {
        /// ControlBooth's AirPlay relay sends Music.app's decoded PCM here.
        var musicIn: UInt16
        /// Announcer PCM (48 kHz / 2 ch S16LE) into the mixer's sidechain input.
        var announcerIn: UInt16
        /// The station PCMMixer's control port (`gain 0 <g>` fades the music).
        var mixerControl: UInt16
        /// AntennaHead's ControlBooth receiver.
        var antennaHead: UInt16
        /// ControlBooth AirPlay relay's PCMUDPSender `--control-port`
        /// (`relay on` / `relay off`), fixed in AirPlayReceiverController.
        var airPlayRelayControl: UInt16
    }

    /// Passed straight to `PCMMixer --duck-*` (start: AntennaHead's filler values).
    struct Duck: Codable {
        var threshold: Double
        var attenuation: Double
        var attackMs: Int
        var releaseMs: Int
        var holdMs: Int
    }

    enum Segment: String, Codable {
        /// Station ID, time, temperature, headlines. Music paused.
        case topOfHour
        /// Forecast. Music paused.
        case weather
        /// Station ID + time only, talked over the end of a song.
        case stationID
    }

    struct ClockEvent: Codable {
        var minute: Int
        var segment: Segment
    }

    var stationName: String
    var slogan: String
    var playlist: String
    var shuffle: Bool
    /// Music.app's name for ControlBooth's AirPlay receiver.
    var airPlayDeviceName: String
    /// How far behind Music.app's `player position` the audio reaches the
    /// mixer (AirPlay buffering). Talk-over timing adds this.
    var airPlayLatencySeconds: Double
    var latitude: Double
    var longitude: Double
    /// NWS requires a User-Agent with contact info.
    var weatherUserAgent: String
    var newsFeeds: [String]
    var headlineCount: Int
    var voice: String?
    var speechRate: Double?
    /// Talk over the end of every Nth song (0 = never).
    var talkOverEvery: Int
    /// Speech ends this long before the song's audio does.
    var talkOverEndGapSeconds: Double
    /// Skip a talk-over whose clip is longer than this.
    var maxTalkOverSeconds: Double
    /// A due clock segment waits for the current song to end, up to this
    /// long; after that the music is faded out for it.
    var maxSegmentWaitSeconds: Double
    /// Write the announcer's lines with Apple's on-device model (falls back
    /// to templates when unavailable or when a line fails the fact check).
    var useAI: Bool
    var clock: [ClockEvent]
    var ports: Ports
    var duck: Duck
    var helpersPath: String
    /// Overrides `helpersPath` for PCMSpeechSynth only (e.g. a PipelineHelpers
    /// build newer than the one bundled in AntennaHead).
    var speechSynthPath: String?
    /// The source name AntennaHead shows ("ControlBooth: <name>").
    var antennaHeadSourceName: String

    static let defaults = StationConfig(
        stationName: "AntennaHead Radio",
        slogan: "your station, on your own terms",
        playlist: "Recently Added",
        shuffle: true,
        airPlayDeviceName: "ControlBooth",
        airPlayLatencySeconds: 2.0,
        latitude: 34.7465,
        longitude: -92.2896,
        weatherUserAgent: "AntennaHead-StationDirector (https://github.com/dsward2)",
        newsFeeds: [
            "https://feeds.npr.org/1001/rss.xml",
            "https://www.kark.com/feed/",
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
        antennaHeadSourceName: "Station"
    )

    static func load(path: String?) throws -> StationConfig {
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as! [String: Any]
        guard let path else { return defaults }
        let data = try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        guard let user = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DirectorError("\(path): top level must be a JSON object")
        }
        let merged = deepMerge(base, user)
        var config = try JSONDecoder().decode(StationConfig.self,
                                              from: JSONSerialization.data(withJSONObject: merged))
        // Relative paths are relative to the config file.
        let dir = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).deletingLastPathComponent()
        if let p = config.speechSynthPath, !p.hasPrefix("/"), !p.hasPrefix("~") {
            config.speechSynthPath = dir.appendingPathComponent(p).standardizedFileURL.path
        }
        return config
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

    func helper(_ name: String) -> String {
        if name == "PCMSpeechSynth", let speechSynthPath { return (speechSynthPath as NSString).expandingTildeInPath }
        return (helpersPath as NSString).appendingPathComponent(name)
    }
}

struct DirectorError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum Log {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func info(_ message: String) {
        FileHandle.standardError.write(Data("[\(formatter.string(from: Date()))] \(message)\n".utf8))
    }
}
