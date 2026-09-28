import Foundation
import Darwin

/// Loopback UDP sender. Unconnected `sendto`, so a port nobody is bound to
/// just drops the datagram instead of failing later sends (unlike
/// PCMUDPSender, which exits on ECONNREFUSED).
public final class UDPOut {
    private let fd: Int32
    private var address = sockaddr_in()

    public init(host: String = "127.0.0.1", port: UInt16) {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &address.sin_addr)
    }

    deinit { close(fd) }

    /// Sends `data` in datagrams of at most `maxDatagram` bytes (2048 matches
    /// PCMUDPSender/PCMMixer; keep it a multiple of the 4-byte stereo frame).
    public func send(_ data: Data, maxDatagram: Int = 2048) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let length = min(maxDatagram, data.count - offset)
                withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        _ = sendto(fd, base + offset, length, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                offset += length
            }
        }
    }

    public func send(_ text: String) { send(Data(text.utf8)) }
}

/// The station's audio graph, built from AntennaHead's own helpers:
///
///     udp:musicIn ─▶ PCMUDPReceiver --fill-silence ─▶ PCMMixer input 0 (music, clock master)
///     udp:announcerIn ───────────────────────────────▶ PCMMixer input 1 (announcer, ducks input 0)
///                                                     │ stdout
///                                                     ▼
///                                   this process ─▶ udp:antennaHead (or a file)
///
/// The director forwards the mixer's output itself (rather than PCMMixer
/// `--output udp:`) so AntennaHead closing its receiver doesn't kill the
/// station — PCMMixer exits on the first failed send.
public final class AudioGraph {
    public enum Output: Sendable {
        case udp(port: UInt16)
        case file(URL)
    }

    static let sampleRate = 48_000
    static let channels = 2
    static let bytesPerSecond = Double(sampleRate * channels * 2)

    private let config: StationConfig
    private let output: Output
    private let receiver = Process()
    private let mixer = Process()
    private let control: UDPOut
    private(set) var musicGain = 1.0
    var onExit: ((String) -> Void)?
    private let detectorLock = NSLock()
    private var detectorArmed = false
    private var soundAt: Date?

    init(config: StationConfig, output: Output) {
        self.config = config
        self.output = output
        control = UDPOut(port: config.ports.mixerControl)
    }

    func start() throws {
        let p = config.ports
        let d = config.duck
        receiver.executableURL = URL(fileURLWithPath: config.helper("PCMUDPReceiver"))
        receiver.arguments = ["--port", "\(p.musicIn)", "--fill-silence",
                              "--rate", "\(Self.sampleRate)", "--channels", "\(Self.channels)",
                              "--exit-with-parent"]
        mixer.executableURL = URL(fileURLWithPath: config.helper("PCMMixer"))
        mixer.arguments = ["--input", "stdin", "--input", "udp:\(p.announcerIn)",
                           "--rate", "\(Self.sampleRate)", "--channels", "\(Self.channels)",
                           "--control-port", "\(p.mixerControl)",
                           "--duck-input", "1",
                           "--duck-threshold", "\(d.threshold)",
                           "--duck-attenuation", "\(d.attenuation)",
                           "--duck-attack-ms", "\(d.attackMs)",
                           "--duck-release-ms", "\(d.releaseMs)",
                           "--duck-hold-ms", "\(d.holdMs)",
                           "--exit-with-parent"]
        let link = Pipe()
        let out = Pipe()
        receiver.standardOutput = link
        mixer.standardInput = link
        mixer.standardOutput = out
        for process in [receiver, mixer] {
            process.terminationHandler = { [weak self] proc in
                let name = proc.executableURL?.lastPathComponent ?? "helper"
                self?.onExit?("\(name) exited (status \(proc.terminationStatus))")
            }
        }
        try mixer.run()
        try receiver.run()
        startForwarding(out.fileHandleForReading)
        Log.info("audio graph up: music udp:\(p.musicIn) + announcer udp:\(p.announcerIn) → "
                 + describe(output) + ", mixer control udp:\(p.mixerControl)")
    }

    func stop() {
        for process in [receiver, mixer] where process.isRunning {
            process.terminationHandler = nil
            process.terminate()
        }
    }

    /// Sets the music (input 0) gain. The duck envelope applies on top of it.
    func setMusicGain(_ gain: Double) {
        musicGain = gain
        control.send("gain 0 \(String(format: "%.3f", gain))\n")
    }

    /// Linear ramp of the music gain, in 50 ms steps.
    func fadeMusic(to target: Double, over seconds: Double) async {
        let start = musicGain
        let steps = max(1, Int(seconds / 0.05))
        for i in 1...steps {
            setMusicGain(start + (target - start) * Double(i) / Double(steps))
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Arms a one-shot detector for the first non-silent mixer output, used to
    /// measure the AirPlay latency (Music.app `play` → audio at the mixer).
    func armSoundDetector() {
        detectorLock.withLock { detectorArmed = true; soundAt = nil }
    }

    var firstSoundAt: Date? { detectorLock.withLock { soundAt } }

    private func detectSound(_ data: Data) {
        guard detectorLock.withLock({ detectorArmed }) else { return }
        let loud = data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).contains { abs(Int32($0)) > 300 }   // ≈ −40 dBFS
        }
        if loud {
            detectorLock.withLock { detectorArmed = false; soundAt = Date() }
        }
    }

    private func describe(_ output: Output) -> String {
        switch output {
        case .udp(let port): return "udp:\(port)"
        case .file(let url): return url.path
        }
    }

    private func startForwarding(_ handle: FileHandle) {
        let sink: (Data) -> Void
        switch output {
        case .udp(let port):
            let udp = UDPOut(port: port)
            sink = { udp.send($0) }
        case .file(let url):
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let file = try? FileHandle(forWritingTo: url)
            sink = { file?.write($0) }
        }
        let thread = Thread {
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                self.detectSound(data)
                sink(data)
            }
        }
        thread.name = "mixer-output"
        // Every block of the station's audio passes through here, so it must
        // not fall behind: when it does, the mixer blocks, the fill-silence
        // receiver skips the missed time, and AntennaHead gets less than
        // real-time audio (late HLS segments, stalled players). The host app
        // should also hold a ProcessInfo activity while on air (App Nap).
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}
