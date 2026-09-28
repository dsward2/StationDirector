import Foundation

let usage = """
station-director — AntennaHead station automation (first-hour prototype)

  station-director run     [--config station.json] [--output antennahead|udp:<port>|file:<path>]
                           [--no-music] [--fire topOfHour|weather|stationID] [--minutes <n>]
  station-director preview [--config station.json]   print the hour's lines; no audio
  station-director say     [--config station.json] <text>   speak into a running station
  station-director config                             print the effective default config

run: announces the "Station" source to AntennaHead, starts the audio graph
(PCMUDPReceiver udp:6031 + PCMMixer with the announcer on udp:6032), switches
ControlBooth's AirPlay relay on, and plays the playlist on Music.app's
"ControlBooth" AirPlay device. Ctrl-C stops Music, the relay and the graph.
"""

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

func take(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

func takeFlag(_ flag: String) -> Bool {
    guard let i = args.firstIndex(of: flag) else { return false }
    args.remove(at: i)
    return true
}

do {
    let config = try StationConfig.load(path: take("--config"))
    switch command {
    case "run":
        let outputArg = take("--output") ?? "antennahead"
        let output: AudioGraph.Output
        if outputArg == "antennahead" {
            output = .udp(port: config.ports.antennaHead)
        } else if outputArg.hasPrefix("udp:"), let port = UInt16(outputArg.dropFirst(4)) {
            output = .udp(port: port)
        } else if outputArg.hasPrefix("file:") {
            output = .file(URL(fileURLWithPath: String(outputArg.dropFirst(5))))
        } else {
            throw DirectorError("bad --output '\(outputArg)'")
        }
        var fire: StationConfig.Segment?
        if let f = take("--fire") {
            guard let segment = StationConfig.Segment(rawValue: f) else { throw DirectorError("bad --fire '\(f)'") }
            fire = segment
        }
        let options = Director.Options(output: output,
                                       announceToAntennaHead: outputArg == "antennahead",
                                       controlMusic: !takeFlag("--no-music"),
                                       fireAtStart: fire,
                                       runMinutes: take("--minutes").flatMap(Double.init))
        try await Director(config: config, options: options).run()
        exit(0)
    case "preview":
        let options = Director.Options(output: .udp(port: 0), announceToAntennaHead: false,
                                       controlMusic: false, fireAtStart: nil, runMinutes: nil)
        await Director(config: config, options: options).preview()
    case "say":
        let text = args.joined(separator: " ")
        guard !text.isEmpty else { throw DirectorError("say: no text") }
        try await Announcer(config: config).speak(text)
    case "config":
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(config), as: UTF8.self))
    default:
        print(usage)
        exit(2)
    }
} catch {
    Log.info("error: \(error)")
    exit(1)
}
