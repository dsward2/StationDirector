import Foundation
import Observation

/// The hour clock. Polls Music.app four times a second and decides when to
/// talk over a song's ending and when to stop the music for a clock segment.
///
/// AirPlay timing: what the mixer hears lags Music.app's `player position` by
/// the AirPlay latency (measured at startup). Segments never pause Music:
/// a pause longer than a few seconds leaves ControlBooth's shairport-sync
/// holding a dead session, after which Music can't resume or reconnect
/// ("The network connection was reset"). Instead, once the *next* track has
/// run for just under the latency (the old song has played out), the mixer
/// mutes the music, the segment speaks, Music seeks that track back to 0 one
/// latency before the voice ends, and the music is unmuted as the voice ends.
@MainActor
@Observable
public final class Director {
    public struct Options {
        public var output: AudioGraph.Output
        public var announceToAntennaHead: Bool
        public var controlMusic: Bool
        public var fireAtStart: StationConfig.Segment?
        public var runMinutes: Double?

        public init(output: AudioGraph.Output, announceToAntennaHead: Bool, controlMusic: Bool,
                    fireAtStart: StationConfig.Segment? = nil, runMinutes: Double? = nil) {
            self.output = output
            self.announceToAntennaHead = announceToAntennaHead
            self.controlMusic = controlMusic
            self.fireAtStart = fireAtStart
            self.runMinutes = runMinutes
        }
    }

    public enum Phase: Equatable, Sendable {
        case starting
        case onAir
        case segment(StationConfig.Segment)
        case stopping
        case stopped
    }

    // MARK: Status (for a UI)

    public private(set) var phase: Phase = .stopped
    /// "Title — Artist" of the song Music.app is playing.
    public private(set) var nowPlaying: String?
    /// The announcer's most recent line.
    public private(set) var lastLine: String?
    /// The AirPlay latency in use (measured at startup when possible).
    public private(set) var latency: Double
    /// Segments waiting for a song boundary.
    public var pendingSegments: [StationConfig.Segment] { pending.map(\.segment) }
    /// Why the station stopped on its own, if it did.
    public private(set) var failure: String?

    private struct PendingSegment {
        let segment: StationConfig.Segment
        let due: Date
        let clip: Task<Clip?, Never>
    }

    private let config: StationConfig
    private let options: Options
    private let graph: AudioGraph
    private let announcer: Announcer
    private let music = MusicPlayer()
    private let weather: Weather
    private let copy: Copywriter
    private let relay: MusicRelay?

    private var stopping = false
    private var fatal: String?
    private var currentTrack: MusicPlayer.Track?
    private var songCount = 0
    /// The rendered talk-over for the current song, once it's ready.
    private var talkOverClip: Clip?
    private var talkOverGeneration = 0
    private var talkOverStarted = false
    private var trackStartedAt: [String: Date] = [:]
    /// The current song gets a talk-over, written once it's close to its end
    /// (so the time and temperature in it are current).
    private var talkOverDue = false
    /// When Music was first seen not playing outside a segment (watchdog).
    private var musicStoppedSince: Date?
    private var talkOverRequested = false
    /// Music-stopping segments waiting for a song boundary, in due order.
    private var pending: [PendingSegment] = []
    private var firedClockKeys = Set<String>()
    /// Music.app's AirPlay selection before the station took it over.
    private var previousAirPlayDevices: [String] = []

    /// `relay` is required when `options.controlMusic` is on.
    public init(config: StationConfig, options: Options, relay: MusicRelay?) {
        self.config = config
        self.options = options
        graph = AudioGraph(config: config, output: options.output)
        announcer = Announcer(config: config)
        weather = Weather(config: config)
        copy = Copywriter(useAI: config.useAI)
        self.relay = relay
        latency = config.airPlayLatencySeconds
    }

    /// Asks a running station to stop; `run()` returns once it has.
    public func stop() {
        guard phase != .stopped else { return }
        stopping = true
        phase = .stopping
    }

    /// Synchronous last-ditch stop for app termination, when `run()` won't
    /// get another turn: pauses Music, gives the AirPlay receiver back, and
    /// tells AntennaHead the source is gone. The helpers exit with the app.
    public func stopImmediately() {
        guard phase != .stopped else { return }
        if options.controlMusic {
            try? music.pause()
            if !previousAirPlayDevices.isEmpty, previousAirPlayDevices != [config.airPlayDeviceName] {
                try? music.selectAirPlayDevices(named: previousAirPlayDevices)
            }
            relay?.setRelay(false)
        }
        graph.stop()
        if options.controlMusic { relay?.finish() }
        if options.announceToAntennaHead {
            AntennaHeadLink.stopListening(config.antennaHeadSourceName)
        }
        stopping = true
        phase = .stopped
    }

    /// Runs `segment` now — at the next song boundary for the music-stopping
    /// ones, over the end of the current song for a station ID.
    public func fire(_ segment: StationConfig.Segment) {
        guard phase != .stopped, phase != .stopping else { return }
        queue(segment, due: Date())
    }

    // MARK: Lifecycle

    public func run() async throws {
        phase = .starting
        failure = nil
        do {
            try await start()
        } catch {
            failure = "\(error)"
            await shutdown()
            throw error
        }
        phase = stopping ? .stopping : .onAir

        let started = Date()
        while !stopping && fatal == nil {
            if let minutes = options.runMinutes, Date().timeIntervalSince(started) > minutes * 60 { break }
            do {
                try await tick()
            } catch {
                Log.info("tick: \(error)")
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if let fatal {
            Log.info("stopping: \(fatal)")
            failure = fatal
        }
        await shutdown()
    }

    private func start() async throws {
        if options.announceToAntennaHead {
            guard AntennaHeadLink.isRunning else { throw DirectorError("AntennaHead is not running") }
            // Off the main actor: the send blocks until AntennaHead has bound its receiver.
            let name = config.antennaHeadSourceName
            try await Task.detached(priority: .userInitiated) { try AntennaHeadLink.startListening(name) }.value
            Log.info("AntennaHead is listening to '\(config.antennaHeadSourceName)'")
        }
        graph.onExit = { [weak self] reason in
            Task { @MainActor in self?.fatal = reason }
        }
        if options.controlMusic, let relay {
            await relay.prepare(port: config.ports.musicIn)
        }
        try graph.start()
        try await Task.sleep(for: .milliseconds(300))

        if options.controlMusic {
            relay?.setRelay(true)
            Log.info("AirPlay relay on (ControlBooth → udp:\(config.ports.musicIn))")
            previousAirPlayDevices = music.selectedAirPlayDevices()
            try await selectAirPlayDevice()
            graph.armSoundDetector()
            try music.play(playlist: config.playlist, shuffle: config.shuffle)
            Log.info("Music.app → AirPlay '\(config.airPlayDeviceName)', playlist '\(config.playlist)'"
                     + (config.shuffle ? " (shuffle)" : ""))
            await measureLatency()
        }
        if let segment = options.fireAtStart {
            queue(segment, due: Date())
        } else {
            // Opening ID over the first song's intro.
            let facts = await makeFacts()
            let line = await copy.stationID(facts)
            if let clip = try? await announcer.render(line) {
                try? await Task.sleep(for: .seconds(1))
                await speak(clip)
            }
        }
    }

    /// Selects the station's AirPlay device, retrying while it (re)appears —
    /// a just-restarted receiver takes a few seconds to be advertised again.
    private func selectAirPlayDevice() async throws {
        var lastError: Error?
        for _ in 0..<30 {
            do {
                try music.selectAirPlayDevice(named: config.airPlayDeviceName)
                return
            } catch {
                lastError = error
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        throw lastError ?? DirectorError("AirPlay device '\(config.airPlayDeviceName)' not found")
    }

    private func speak(_ clip: Clip) async {
        lastLine = clip.text
        await announcer.play(clip)
    }

    /// Time from Music.app's playhead to sound at the mixer: the first sound
    /// minus the moment the playhead was at 0. Waits for Music to report
    /// "playing" first — connecting to the AirPlay receiver can take 30 s.
    /// Falls back to the configured value if nothing arrives.
    private func measureLatency() async {
        var trackZeroAt: Date?
        for _ in 0..<150 where trackZeroAt == nil {
            if let s = try? music.state(), s.playing {
                trackZeroAt = Date().addingTimeInterval(-s.position)
            } else {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        guard let playAt = trackZeroAt else {
            Log.info("Music.app didn't start playing within 30s; using \(latency)s")
            return
        }
        for _ in 0..<40 {
            if let at = graph.firstSoundAt {
                let measured = at.timeIntervalSince(playAt)
                if (0.3...6).contains(measured) {
                    latency = measured
                    Log.info("AirPlay latency measured: \(String(format: "%.2f", measured))s")
                } else {
                    Log.info("AirPlay latency measurement \(String(format: "%.2f", measured))s out of range; using \(latency)s")
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        Log.info("no music reached the mixer within 8s — check ControlBooth's AirPlay port (\(config.ports.musicIn)) "
                 + "and that Music.app is playing to '\(config.airPlayDeviceName)'; using \(latency)s")
    }

    private func shutdown() async {
        phase = .stopping
        Log.info("shutting down")
        if options.controlMusic {
            try? music.pause()
            // Switching away makes Music close its ControlBooth session
            // cleanly instead of leaving it idle and paused.
            if !previousAirPlayDevices.isEmpty, previousAirPlayDevices != [config.airPlayDeviceName] {
                try? music.selectAirPlayDevices(named: previousAirPlayDevices)
            }
            relay?.setRelay(false)
            try? await Task.sleep(for: .milliseconds(300))   // let the relay-off land before the port closes
        }
        graph.stop()
        if options.controlMusic { relay?.finish() }
        if options.announceToAntennaHead {
            AntennaHeadLink.nowPlaying("", source: config.antennaHeadSourceName)
            AntennaHeadLink.stopListening(config.antennaHeadSourceName)
        }
        nowPlaying = nil
        phase = .stopped
    }

    // MARK: Clock

    private func tick() async throws {
        checkClock()
        let state: MusicPlayer.State
        if options.controlMusic {
            state = try music.state()
        } else {
            state = MusicPlayer.State(playing: false, position: 0, track: nil)
        }
        if let track = state.track, track != currentTrack {
            trackChanged(to: track)
        }
        if options.controlMusic && pending.isEmpty {
            if state.playing {
                musicStoppedSince = nil
            } else if let since = musicStoppedSince {
                if Date().timeIntervalSince(since) > 8 {
                    Log.info("watchdog: Music.app isn't playing; restarting it")
                    musicStoppedSince = nil
                    try music.resume(playlist: config.playlist, shuffle: config.shuffle)
                }
            } else {
                musicStoppedSince = Date()
            }
        }

        if let segment = pending.first {
            try await handlePending(segment, state: state)
            return
        }
        if talkOverDue, !talkOverRequested, let track = currentTrack, state.playing,
           state.remaining + latency < 45 {
            requestTalkOver(for: track)
        }
        // An unready clip just misses this song.
        guard state.playing, !talkOverStarted, let clip = talkOverClip else { return }
        let audibleRemaining = state.remaining + latency
        if audibleRemaining <= clip.duration + config.talkOverEndGapSeconds {
            talkOverStarted = true
            if audibleRemaining < clip.duration * 0.6 {
                Log.info("talk-over missed its window (\(String(format: "%.1f", audibleRemaining))s left)")
                return
            }
            Task { await speak(clip) }
        }
    }

    /// Queues each clock event a minute early, so its copy (model calls,
    /// weather and news fetches, rendering) is ready by the time it's due.
    private func checkClock() {
        let now = Date()
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        for event in config.clock where (event.minute + 59) % 60 == parts.minute {
            let key = "\(parts.year!)-\(parts.month!)-\(parts.day!)-\(parts.hour!)-\(event.minute)-\(event.segment)"
            guard firedClockKeys.insert(key).inserted,
                  let due = calendar.nextDate(after: now, matching: DateComponents(second: 0),
                                              matchingPolicy: .nextTime) else { continue }
            queue(event.segment, due: due)
        }
    }

    private func queue(_ segment: StationConfig.Segment, due: Date) {
        Log.info("clock: \(segment) due at \(due.formatted(date: .omitted, time: .standard))")
        let clip = Task<Clip?, Never> { [weak self] in
            guard let self else { return nil }
            let text = await self.segmentText(segment)
            do {
                return try await self.announcer.render(text)
            } catch {
                Log.info("segment render failed: \(error)")
                return nil
            }
        }
        if segment == .stationID {
            // Talked over the end of the current song, like any talk-over.
            prepareTalkOver { await clip.value }
            talkOverDue = false          // the ID replaces this song's talk-over
            if !options.controlMusic {
                Task { if let c = await clip.value { await speak(c) } }
            }
        } else {
            pending.append(PendingSegment(segment: segment, due: due, clip: clip))
        }
    }

    private func trackChanged(to track: MusicPlayer.Track) {
        currentTrack = track
        trackStartedAt[track.id] = Date()
        songCount += 1
        Log.info("♪ \(track.name) — \(track.artist)  [\(Int(track.duration))s]")
        nowPlaying = "\(track.name) — \(track.artist)"
        if options.announceToAntennaHead {
            AntennaHeadLink.nowPlaying("\(track.name) — \(track.artist)", source: config.antennaHeadSourceName)
        }
        prepareTalkOver { nil }
        let every = config.talkOverEvery
        talkOverDue = pending.isEmpty && every > 0 && songCount % every == 0
        talkOverRequested = false
    }

    private func requestTalkOver(for track: MusicPlayer.Track) {
        talkOverRequested = true
        let upNext = music.upNext()
        prepareTalkOver { [weak self] in
            guard let self else { return nil }
            var facts = await self.makeFacts()
            facts.justPlayed = (track.name, track.artist)
            facts.upNext = upNext
            let line = await self.copy.talkOver(facts)
            return try? await self.announcer.render(line)
        }
    }

    private func prepareTalkOver(_ make: @escaping @MainActor () async -> Clip?) {
        talkOverGeneration += 1
        let generation = talkOverGeneration
        talkOverClip = nil
        talkOverStarted = false
        Task { @MainActor [weak self] in
            let clip = await make()
            guard let self, generation == self.talkOverGeneration else { return }
            self.talkOverClip = clip
        }
    }

    /// Runs a music-stopping segment at the next song boundary, or after
    /// `maxSegmentWaitSeconds` with a fade.
    private func handlePending(_ segment: PendingSegment, state: MusicPlayer.State) async throws {
        let waited = Date().timeIntervalSince(segment.due)
        guard waited >= 0 else { return }
        let newTrackSettled = state.playing && state.position >= latency - 0.25 && state.position < latency + 2
            && currentTrackStartedAfter(segment.due)
        let overdue = state.playing && waited > config.maxSegmentWaitSeconds

        if state.playing && !newTrackSettled && !overdue { return }
        // Music not started yet (AirPlay still connecting): hold the segment.
        if options.controlMusic && !state.playing && currentTrack == nil && waited < 60 { return }
        pending.removeFirst()
        prepareTalkOver { nil }
        talkOverDue = false

        phase = .segment(segment.segment)
        defer { if phase == .segment(segment.segment) { phase = .onAir } }
        let musicWasPlaying = options.controlMusic && state.playing
        if musicWasPlaying {
            if overdue {
                Log.info("segment overdue by \(Int(waited))s; fading the music")
                await graph.fadeMusic(to: 0, over: 2)
                try music.nextTrack()
            } else {
                graph.setMusicGain(0)       // mutes the new track's opening
            }
        }
        if options.announceToAntennaHead {
            AntennaHeadLink.nowPlaying("\(config.stationName) — \(segment.segment == .weather ? "Weather" : "News")",
                                       source: config.antennaHeadSourceName)
        }
        let clip = await segment.clip.value
        let duration = clip?.duration ?? 0
        // Seek back to 0 one latency before the voice ends, so the song's
        // start reaches the mixer just as the voice finishes; unmute then.
        let seekAfter = max(0, duration - latency)
        let seekTask = Task { @MainActor [music] in
            try? await Task.sleep(for: .seconds(seekAfter))
            if musicWasPlaying { try? music.seekToStart() }
        }
        if let clip { await speak(clip) }
        _ = await seekTask.value
        let unmuteIn = seekAfter + latency - duration
        if unmuteIn > 0 { try? await Task.sleep(for: .seconds(unmuteIn)) }
        graph.setMusicGain(1)
        if options.controlMusic && !musicWasPlaying {
            try? music.resume(playlist: config.playlist, shuffle: config.shuffle)
        }
        currentTrack = nil      // re-announce the track to Now Playing
        songCount = 0
    }

    private func currentTrackStartedAfter(_ date: Date) -> Bool {
        guard let track = currentTrack else { return false }
        return (trackStartedAt[track.id] ?? .distantPast) > date
    }

    // MARK: Copy

    private func makeFacts() async -> Facts {
        let now = try? await weather.current()
        return Facts(stationName: config.stationName, slogan: config.slogan,
                     time: SpokenTime.clock(Date()), city: await weather.city.flatMap { $0.isEmpty ? nil : $0 },
                     temperatureF: now?.temperatureF, conditions: now?.conditions,
                     justPlayed: nil, upNext: nil)
    }

    public func segmentText(_ segment: StationConfig.Segment) async -> String {
        let facts = await makeFacts()
        switch segment {
        case .stationID:
            return await copy.stationID(facts)
        case .topOfHour:
            let headlines = await News.headlines(feeds: config.newsFeeds, count: config.headlineCount)
            return await copy.topOfHour(facts, hour: SpokenTime.hour(Date()), headlines: headlines)
        case .weather:
            let periods = (try? await weather.forecast()) ?? []
            return copy.weather(facts, periods: periods)
        }
    }

    /// Every line the next hour would use, as text; no audio.
    public func preview() async -> String {
        let facts = await makeFacts()
        var out = "Facts:\n\(facts.listing)\n\n"
        for event in config.clock {
            out += ":\(String(format: "%02d", event.minute)) \(event.segment.rawValue):\n  \(await segmentText(event.segment))\n\n"
        }
        var f = facts
        f.justPlayed = ("Dreams", "Fleetwood Mac")
        out += "talk-over (sample):\n  \(await copy.talkOver(f))\n"
        return out
    }
}

enum SpokenTime {
    /// "4:15", or "5 o'clock" on the hour.
    static func clock(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let h = (c.hour! + 11) % 12 + 1
        return c.minute! == 0 ? "\(h) o'clock" : String(format: "%d:%02d", h, c.minute!)
    }

    /// The hour for a top-of-hour ID: "5 o'clock", or the half past it rounds to.
    static func hour(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let rounded = c.minute! >= 30 ? c.hour! + 1 : c.hour!
        return "\((rounded + 11) % 12 + 1) o'clock"
    }
}
