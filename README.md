# StationDirector

First-hour prototype of AntennaHead station automation. The design is in
`../antennahead-workspace/STATION_AUTOMATION_DESIGN.md`. This is a standalone
Swift CLI; the plan is to fold it into ControlBooth later.

It plays a Music.app playlist through AntennaHead's stream, with a synthesized
announcer that talks over the end of each song, reads a top-of-hour ID with
time, temperature and three headlines at :00, and reads the NWS forecast at
:30. On-device Foundation Models writes the wording. The facts come only from
Music.app, NWS and RSS, and any model line that names something not in those
facts is replaced by a template line.

## Audio path

```
Music.app ─AirPlay─▶ ControlBooth receiver ─relay─▶ udp:6031
   PCMUDPReceiver --fill-silence ─▶ PCMMixer input 0 (music, clock master)
   announcer PCM ─────── udp:6032 ─▶ PCMMixer input 1 (ducks the music ≈ −12 dB)
   PCMMixer stdout ─▶ station-director ─▶ udp:6019 (AntennaHead, source "Station")
   mixer control: udp:6033 (the director fades music with `gain 0 <g>`)
```

The helpers are AntennaHead's own (`/Applications/AntennaHead.app/Contents/Helpers`).
Differences from the design doc:

- **No ControlBooth pipelines.** The director launches the receiver and mixer
  itself and sends 'Strt'/'NpUp'/'Stop' AppleEvents to AntennaHead the way
  ControlBooth does. It forwards the mixer's output itself, because PCMMixer
  and PCMUDPSender exit on a failed send. That way the station survives
  AntennaHead switching sources.
- **No long-running announcer stage.** Each line is rendered ahead of time with
  `PCMSpeechSynth --no-pace` and sent paced by the director. The clip length
  is exact before it plays, which settles §8 item 6 without a `--done-port`.
- **AirPlay relay switched directly.** ControlBooth's AirPlay setting stays on
  **Receiving** (not "Receiving & Relayed", which would announce "AirPlay
  Receiver" to AntennaHead). The director sends `relay on` to the relay's
  control port (6029) once 6031 is listening, and `relay off` before it exits.
- **AirPlay latency is measured** at startup: the time from Music `play` to
  the first sound at the mixer. Talk-over timing uses it. Pausing Music for a
  segment flushes shairport-sync's buffer, so a segment pauses about one
  latency into the *next* track (the old song has played out), rewinds that
  track to 0, speaks, and resumes Music one latency before the voice ends.

## One-time setup

1. ControlBooth › AirPlay settings: **Destination Port 6031**, mode **Receiving**.
2. Build: `swift build` (and, until PipelineHelpers#18 ships in AntennaHead,
   `swift build -c release --product PCMSpeechSynth` in `../PipelineHelpers`;
   `station.example.json` points `speechSynthPath` at that build. The
   bundled PCMSpeechSynth cuts off anything longer than about 15 s).
3. `cp station.example.json station.json` and edit. Every key is optional.
   `station-director config` prints all keys and their defaults.
4. First run: allow the Automation prompts (Music, AntennaHead).

## Commands

```
station-director preview --config station.json        # print the hour's lines; no audio
station-director run --config station.json            # on air, Ctrl-C to stop
station-director run --config station.json --fire topOfHour   # run a segment right away
station-director run --no-music --output file:/tmp/out.raw --fire weather   # offline test
station-director say --config station.json "Testing one two"  # into a running station
```

`--output` is `antennahead` (default), `udp:<port>` or `file:<path>` (48 kHz / 2 ch S16LE).
`--no-music` leaves Music.app and the relay alone; feed 6031 yourself.

## Known limits

- If the director is killed without its Ctrl-C cleanup, the AirPlay relay stays on
  and ControlBooth's relay sender exits on its next send to the closed 6031.
  Re-select the AirPlay mode in ControlBooth to restart it.
- `upNext` (introducing the next song) works only with shuffle off.
- The ControlBooth UI doesn't know the relay was switched on from outside.
