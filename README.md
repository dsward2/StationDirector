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
- **AirPlay latency is measured** at startup: the time from Music's playhead
  at 0 to the first sound at the mixer (1.4 s on the Mac mini). Talk-over timing
  uses it, and talk-over lines are written about 45 s before the song ends, so
  the time in them is current.
- **Segments never pause Music.** If Music pauses an AirPlay stream to
  ControlBooth for more than a few seconds, shairport-sync keeps a dead
  session: Music can't resume or reconnect ("The network connection was
  reset"), and the receiver has to be restarted (ControlBooth › AirPlay
  Receiver › Not in Use, Save, then Receiving, Save). So at the first song boundary after a
  segment is due, the mixer mutes the music. The segment speaks while Music
  plays on silently. One latency before the voice ends, Music seeks the track
  back to 0, and the music is unmuted as the voice ends. At shutdown the director
  pauses Music and switches its output back to the devices selected before,
  so Music closes the session.

## One-time setup

1. ControlBooth › AirPlay settings: **Destination Port 6031**, mode **Receiving**.
2. Build: `swift build`. AntennaHead must include PipelineHelpers#18 (merged
   2026-09-27); older bundled PCMSpeechSynth cuts off anything longer than
   about 15 s. `speechSynthPath` in `station.json` can point at another build.
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
- Taking over AntennaHead's 6019 receiver stops whatever ControlBooth pipeline
  was playing there (its PCMUDPSender exits). Restart it after the station.
- A segment due while a very long track is playing waits up to
  `maxSegmentWaitSeconds`, then fades the music and skips to the next track.
- The ControlBooth UI doesn't know the relay was switched on from outside.
