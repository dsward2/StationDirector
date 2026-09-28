import AppKit

/// Speaks ControlBooth's side of the AppleEvents control channel (class
/// 'AntH'; see ControlBooth's AntennaHeadClient.swift), so AntennaHead treats
/// the station like any other ControlBooth pipeline:
///   'Strt' <name>              open the 6019 receiver; reply once it's bound
///   'Stop' <name>              drop back to the filler
///   'NpUp' <text> 'Srce' <name> Now Playing text for that source
/// The first send triggers macOS's Automation consent prompt.
enum AntennaHeadLink {
    static let bundleIdentifier = "com.dsward.AntennaHead"

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    static func startListening(_ name: String) throws {
        try send("Strt", NSAppleEventDescriptor(string: name))
    }

    static func stopListening(_ name: String) {
        try? send("Stop", NSAppleEventDescriptor(string: name), waitForReply: false)
    }

    static func nowPlaying(_ text: String, source: String) {
        try? send("NpUp", NSAppleEventDescriptor(string: text),
                  extra: [fourCC("Srce"): NSAppleEventDescriptor(string: source)], waitForReply: false)
    }

    private static func send(_ eventID: String, _ direct: NSAppleEventDescriptor?,
                             extra: [FourCharCode: NSAppleEventDescriptor] = [:],
                             waitForReply: Bool = true) throws {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            throw DirectorError("AntennaHead is not running")
        }
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: fourCC("AntH"), eventID: fourCC(eventID),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: app.processIdentifier),
            returnID: AEReturnID(-1), transactionID: AETransactionID(0))
        if let direct { event.setParam(direct, forKeyword: fourCC("----")) }
        for (key, value) in extra { event.setParam(value, forKeyword: key) }
        let reply = try event.sendEvent(options: waitForReply ? [.waitForReply] : [.noReply],
                                        timeout: waitForReply ? 8 : 0)
        if waitForReply, let code = reply.paramDescriptor(forKeyword: fourCC("errn"))?.int32Value, code != 0 {
            throw DirectorError(reply.paramDescriptor(forKeyword: fourCC("errs"))?.stringValue
                                ?? "AntennaHead returned Apple Event error \(code)")
        }
    }

    private static func fourCC(_ code: String) -> FourCharCode {
        code.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }
}

/// Gets Music.app's audio (via ControlBooth's AirPlay receiver) to the
/// station's music port. The director calls `prepare` before it binds that
/// port, `setRelay(true)` once it's listening, and `setRelay(false)` +
/// `finish()` when it stops — ControlBooth's relay PCMUDPSender exits if it
/// sends to a port nobody is bound to.
@MainActor
public protocol MusicRelay: AnyObject {
    /// Point the AirPlay receiver's relay at `port` (relay still off).
    func prepare(port: UInt16) async
    func setRelay(_ on: Bool)
    /// Give the receiver back to its normal settings.
    func finish()
}

/// For the command-line tool: ControlBooth's AirPlay setting is left on
/// "Receiving" with its Destination Port set to the station's music port by
/// hand, and the relay is switched through its PCMUDPSender's control port.
@MainActor
public final class UDPRelayControl: MusicRelay {
    private let control: UDPOut

    public init(port: UInt16) { control = UDPOut(port: port) }

    public func prepare(port: UInt16) async {}
    public func setRelay(_ on: Bool) { control.send("relay \(on ? "on" : "off")\n") }
    public func finish() {}
}
