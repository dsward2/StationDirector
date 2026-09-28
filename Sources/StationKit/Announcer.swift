import Foundation

/// A rendered announcer line: 48 kHz / 2 ch S16LE, ready for the mixer.
struct Clip {
    let text: String
    let pcm: Data
    var duration: Double { Double(pcm.count) / AudioGraph.bytesPerSecond }
}

/// Speaks into the station mixer's sidechain input.
///
/// Rather than the design's long-running `PCMSpeechSynth --input udp:` stage,
/// each line is rendered ahead of time with `PCMSpeechSynth --no-pace` (same
/// voices and SSML handling as AntennaHead's filler announcer) and then sent
/// paced by this process. That gives the exact clip length before it plays,
/// which is what talk-over timing needs, and an exact "done" moment — the
/// §8 item 6 end-of-speech problem goes away without a PipelineHelpers change.
public final class Announcer {
    private let config: StationConfig
    private let out: UDPOut

    public init(config: StationConfig) {
        self.config = config
        out = UDPOut(port: config.ports.announcerIn)
    }

    func render(_ text: String) async throws -> Clip {
        let config = self.config
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: config.helper("PCMSpeechSynth"))
            var args = ["--text", SpokenTime.speakable(text), "--rate", "\(AudioGraph.sampleRate)", "--no-pace"]
            if let voice = config.voice { args += ["--voice", voice] }
            if let rate = config.speechRate { args += ["--speech-rate", String(format: "%.3f", rate)] }
            if text.hasPrefix("<speak") { args.append("--ssml") }
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let mono = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, !mono.isEmpty else {
                throw DirectorError("PCMSpeechSynth failed (status \(process.terminationStatus)) for: \(text)")
            }
            return Clip(text: text, pcm: Self.monoToStereo(mono))
        }.value
    }

    /// Sends the clip in real time and returns when its last sample has been
    /// handed to the mixer (the mixer buffers ~`lead` ahead, so listeners hear
    /// the end about that much later).
    func play(_ clip: Clip) async {
        Log.info("🎙  \(String(format: "%.1f", clip.duration))s: \(clip.text)")
        let out = self.out
        await Task.detached(priority: .userInitiated) { Self.sendPaced(clip, to: out) }.value
    }

    private static func sendPaced(_ clip: Clip, to out: UDPOut) {
        let chunk = 1920                       // 10 ms at 48 kHz stereo
        let lead = 0.2                         // stay this far ahead of real time
        let start = Date()
        var offset = 0
        while offset < clip.pcm.count {
            let sentSeconds = Double(offset) / AudioGraph.bytesPerSecond
            let wait = sentSeconds - lead - Date().timeIntervalSince(start)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            let end = min(offset + chunk, clip.pcm.count)
            out.send(clip.pcm.subdata(in: offset..<end))
            offset = end
        }
        let remaining = clip.duration - Date().timeIntervalSince(start)
        if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
    }

    public func speak(_ text: String) async throws {
        await play(try await render(text))
    }

    private static func monoToStereo(_ mono: Data) -> Data {
        var stereo = Data(count: (mono.count / 2) * 4)
        mono.withUnsafeBytes { src in
            stereo.withUnsafeMutableBytes { dst in
                let s = src.bindMemory(to: Int16.self)
                let d = dst.bindMemory(to: Int16.self)
                for i in 0..<s.count {
                    d[2 * i] = s[i]
                    d[2 * i + 1] = s[i]
                }
            }
        }
        return stereo
    }
}
