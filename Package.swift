// swift-tools-version: 6.2
import PackageDescription

// StationDirector — first-hour prototype of AntennaHead station automation
// (see antennahead-workspace/STATION_AUTOMATION_DESIGN.md). A standalone CLI
// that runs the station's audio graph out of AntennaHead's own helpers,
// drives Music.app over AppleScript, and speaks an hourly clock of station
// IDs, time/temperature, headlines and weather over the music.
let package = Package(
    name: "StationDirector",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "station-director",
            path: "Sources/StationDirector",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
