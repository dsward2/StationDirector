import Foundation

/// The hour clock. Polls Music.app four times a second and decides when to
/// talk over a song's ending and when to stop the music for a clock segment.
///
/// AirPlay timing: what the mixer hears lags Music.app's `player position` by
/// `airPlayLatencySeconds`, and pausing makes shairport-sync FLUSH whatever
/// it's still holding. So a segment never pauses at the end of a song (that
/// would cut its last ~2 s); it pauses once the *next* track has run for
/// just under the latency — the old song has played out, and the flush drops
/// only the new track's opening, which is replayed from 0 afterwards.
@MainActor
final class Director {
    struct Options {
        var output: AudioGraph.Output
        var announceToAntennaHead: Bool
        var controlMusic: Bool
        var fireAtStart: StationConfig.Segment?
        var runMinutes: Double?
    }

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
    private let relay: AirPlayRelay
    /// Starts at the config value; replaced by the measured value at startup.
    private var latency: Double

    private var stopping = false
    private var fatal: String?
    private var currentTrack: MusicPlayer.Track?
    private var songCount = 0
    /// The rendered talk-over for the current song, once it's ready.
    private var talkOverClip: Clip?
    private var talkOverGeneration = 0
    private var talkOverStarted = false
    private var trackStartedAt: [String: Date] = [:]
    private var pending: PendingSegment?
    private var firedClockKeys = Set<String>()
    private var signalSources: [DispatchSourceSignal] = []

    init(config: StationConfig, options: Options) {
        self.config = config
        self.options = options
        graph = AudioGraph(config: config, output: options.output)
        announcer = Announcer(config: config)
        weather = Weather(config: config)
        copy = Copywriter(useAI: config.useAI)
        relay = AirPlayRelay(port: config.ports.airPlayRelayControl)
        latency = config.airPlayLatencySeconds
    }

    // MARK: Lifecycle

    func run() async throws {
        installSignalHandlers()
        if options.announceToAntennaHead {
            guard AntennaHeadLink.isRunning else { throw DirectorError("AntennaHead is not running") }
            try AntennaHeadLink.startListening(config.antennaHeadSourceName)
            Log.info("AntennaHead is listening to '\(config.antennaHeadSourceName)'")
        }
        graph.onExit = { [weak self] reason in
            Task { @MainActor in self?.fatal = reason }
        }
        try graph.start()
        try await Task.sleep(for: .milliseconds(300))

        if options.controlMusic {
            relay.set(true)
            Log.info("AirPlay relay on (ControlBooth → udp:\(config.ports.musicIn))")
            try music.selectAirPlayDevice(named: config.airPlayDeviceName)
            graph.armSoundDetector()
            let playAt = Date()
            try music.play(playlist: config.playlist, shuffle: config.shuffle)
            Log.info("Music.app → AirPlay '\(config.airPlayDeviceName)', playlist '\(config.playlist)'"
                     + (config.shuffle ? " (shuffle)" : ""))
            await measureLatency(since: playAt)
        }
        if let segment = options.fireAtStart {
            queue(segment, due: Date())
        } else {
            // Opening ID over the first song's intro.
            let facts = await makeFacts()
            let line = await copy.stationID(facts)
            if let clip = try? await announcer.render(line) {
                try? await Task.sleep(for: .seconds(1))
                await announcer.play(clip)
            }
        }

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
        if let fatal { Log.info("stopping: \(fatal)") }
        shutdown()
    }

    /// Time from Music.app `play` to sound at the mixer. Falls back to the
    /// configured value if nothing arrives (relay off, wrong AirPlay device…).
    private func measureLatency(since playAt: Date) async {
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

    private func shutdown() {
        Log.info("shutting down")
        if options.controlMusic {
            try? music.pause()
            relay.set(false)
            Thread.sleep(forTimeInterval: 0.3)     // let the relay-off land before 6031 closes
        }
        graph.stop()
        if options.announceToAntennaHead {
            AntennaHeadLink.nowPlaying("", source: config.antennaHeadSourceName)
            AntennaHeadLink.stopListening(config.antennaHeadSourceName)
        }
    }

    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.stopping = true }
            }
            source.resume()
            signalSources.append(source)
        }
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

        if let segment = pending {
            try await handlePending(segment, state: state)
            return
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
            Task { await announcer.play(clip) }
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
            if !options.controlMusic {
                Task { if let c = await clip.value { await announcer.play(c) } }
            }
        } else {
            pending = PendingSegment(segment: segment, due: due, clip: clip)
        }
    }

    private func trackChanged(to track: MusicPlayer.Track) {
        currentTrack = track
        trackStartedAt[track.id] = Date()
        songCount += 1
        Log.info("♪ \(track.name) — \(track.artist)  [\(Int(track.duration))s]")
        if options.announceToAntennaHead {
            AntennaHeadLink.nowPlaying("\(track.name) — \(track.artist)", source: config.antennaHeadSourceName)
        }
        let every = config.talkOverEvery
        guard pending == nil, every > 0, songCount % every == 0 else {
            prepareTalkOver { nil }
            return
        }
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
        pending = nil
        prepareTalkOver { nil }

        if options.controlMusic && state.playing {
            if overdue {
                Log.info("segment overdue by \(Int(waited))s; fading the music")
                await graph.fadeMusic(to: 0, over: 2)
                // The fade happened mid-song: skip on to a fresh track.
                try music.pause()
                try music.skipPaused()
                try await Task.sleep(for: .milliseconds(300))
                graph.setMusicGain(1)
            } else {
                try music.rewindPaused()      // the new track's flushed opening replays from 0
            }
        }
        if options.announceToAntennaHead {
            AntennaHeadLink.nowPlaying("\(config.stationName) — \(segment.segment == .weather ? "Weather" : "News")",
                                       source: config.antennaHeadSourceName)
        }
        guard let clip = await segment.clip.value else {
            if options.controlMusic { try music.play() }
            return
        }
        // Resume Music early by the AirPlay latency so it arrives as the voice ends.
        let resumeAfter = max(0, clip.duration - latency + 0.3)
        let controlMusic = options.controlMusic
        let resume = Task { @MainActor [music] in
            try? await Task.sleep(for: .seconds(resumeAfter))
            if controlMusic { try? music.play() }
        }
        await announcer.play(clip)
        _ = await resume.value
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

    func segmentText(_ segment: StationConfig.Segment) async -> String {
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

    /// Prints every line the next hour would use, without audio.
    func preview() async {
        let facts = await makeFacts()
        print("Facts:\n\(facts.listing)\n")
        for event in config.clock {
            print(":\(String(format: "%02d", event.minute)) \(event.segment):\n  \(await segmentText(event.segment))\n")
        }
        var f = facts
        f.justPlayed = ("Dreams", "Fleetwood Mac")
        print("talk-over (sample):\n  \(await copy.talkOver(f))")
        f.upNext = ("Do It Again", "Steely Dan")
        print("talk-over with up-next (sample):\n  \(await copy.talkOver(f))")
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
