// swift-tools-version: 6.2
import PackageDescription

// StationDirector — AntennaHead station automation (see
// antennahead-workspace/STATION_AUTOMATION_DESIGN.md).
//
//   • StationKit        the station itself: audio graph out of AntennaHead's
//                       helpers, Music.app over AppleScript, the announcer,
//                       NWS weather, RSS headlines and the hour clock. Used by
//                       ControlBooth's "AntennaHead Radio" tab.
//   • station-director  a command-line front end to StationKit, for testing
//                       and headless use.
let package = Package(
    name: "StationDirector",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "StationKit", targets: ["StationKit"]),
        .executable(name: "station-director", targets: ["station-director"]),
    ],
    targets: [
        .target(
            name: "StationKit",
            path: "Sources/StationKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "station-director",
            dependencies: ["StationKit"],
            path: "Sources/StationDirector",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
