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

/// ControlBooth's AirPlay relay, switched directly through its PCMUDPSender's
/// control port. ControlBooth's AirPlay setting stays on "Receiving" (so it
/// never announces itself to AntennaHead); the director turns the relay on
/// only once its own 6031 receiver is listening, and off before it exits —
/// PCMUDPSender exits if it sends to a port nobody is bound to.
struct AirPlayRelay {
    let control: UDPOut

    init(port: UInt16) { control = UDPOut(port: port) }

    func set(_ on: Bool) { control.send("relay \(on ? "on" : "off")\n") }
}
