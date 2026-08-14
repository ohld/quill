# quill

A minimal, local-first macOS meeting recorder + transcriber. One menu-bar
click records your mic and all system audio as two separate tracks; when you
stop, quill transcribes both and writes a speaker-tagged transcript. The
speech model stays on-device.

Named for the feather. Sibling of [parrot](https://github.com/digimata/parrot),
with a single Swift executable packaged as a signed menu-bar app.

## Install

```sh
./Scripts/install-app.sh
```

This builds and ad-hoc signs `~/Applications/Quill.app`, then installs its
LaunchAgent. No administrator password is required. Grant Quill Microphone and
System Audio Recording access on first use.

**Requires:** macOS 14.2+ (Core Audio process taps for system audio — no
virtual device, no kernel extension). Apple Silicon recommended for
transcription speed.

## How to use

1. **Run it** (open `~/Applications/Quill.app`, or let its LaunchAgent start it
   at login).
2. **Click the feather in the menu bar → Start recording.** First use prompts
   for microphone and System Audio Recording permissions. While recording, the
   feather becomes red, macOS shows the purple recording
   indicator, and the menu shows elapsed time plus live mic/system-audio status.
   Quill can also recognize a likely Google Meet in a browser or a Zoom call from
   native macOS window and per-process audio-stream state, then offer this same
   manual Start action in a tray popup. It never starts recording by itself.
3. **Click → Stop recording** when the meeting ends. Transcription starts
   automatically (the menu shows progress). A native Quill notification shows
   the recording start time, a transcript preview, and **Open in Finder** when
   the transcript is ready. If macOS notifications are unavailable, a compact
   popover attached to the feather provides the same Finder action instead;
   the two are never shown together. **Copy Last Transcript Path** in the menu
   copies the absolute path to stable `~/Recordings/latest-transcript.md`, ready
   to paste into an agent or another app.

When a detected call's application audio streams close, Quill offers **Stop
and transcribe** after a short debounce. This observes stream lifecycle rather
than speech or silence, never stops automatically, and needs no browser
extension or network service. Browser audio belongs to the whole browser, not
an individual tab, so Meet suggestions intentionally require both a Meet-titled
window and active Zen input/output streams.

Each session lands in `~/Recordings/<yyyy.MM.dd-HHmm>/`:

| File | Contents |
|---|---|
| `mic.caf` | your side (default input device, AAC) |
| `system.caf` | everything the Mac played — the other side of the call (AAC) |
| `meta.json` | start/end timestamps, duration, per-track start offsets |
| `transcript.json` | canonical transcript — engine provenance + timed, speaker-tagged segments |
| `transcript.md` | the same transcript rendered for reading |
| `transcribe.log` | transcription progress/errors for this session |

The recordings root also contains `latest-transcript.md`: an atomically
updated copy of the newest readable transcript, intended as the one stable
path to hand to another agent or workflow.

Two tracks on purpose: speech models do better on clean single-source audio,
and mic-vs-system is free two-party diarization — `me` vs `them` with no
speaker-identification model. AAC is streamed into CAF to keep long meetings
compact. Stop the recording cleanly: the encoder writes the CAF packet table
on close, and external tools cannot reliably read an actively written file.

## Transcription

Built in, on-device, automatic. This fork defaults to **Parakeet TDT
0.6B v3** via FluidAudio: multilingual (including Russian), fully local, and
very fast on Apple Silicon. The model is already cached on this Mac.

Each track is transcribed separately, shifted by its start offset so both
share one clock, and merged by timestamp. A Unicode-aware echo filter removes
remote speech that the raw MacBook mic heard from the speakers, so it does not
appear once as `mic` and again as `system`. Fine-grained timings stay in JSON;
word-level ASR output is grouped into sentence-sized, role-labelled blocks in
the Markdown file. Jobs run in a serial queue — you can start a new recording
while the last one transcribes. Unfinished jobs resume on next launch (the
filesystem is the queue: a session with `meta.json` but no `transcript.json` is
pending). Failures append to the session's `transcribe.log` and never block
later jobs.

## Config

Optional, at `~/.config/quill/config.json`:

```json
{
  "recordings_dir": "~/Recordings",
  "transcription": {
    "enabled": true
  },
  "speaker_names": { "mic": "Dan", "system": "Remote" },
  "transcript_echo_filter": true,
  "on_stop": "my-hook"
}
```

- `recordings_dir` — where sessions land. Resolution order: `--out` flag >
  config > `~/Recordings`.
- `transcription.enabled` — set `false` to just record.
- `speaker_names` — labels for the dedicated mic and system tracks.
- `mic_voice_processing` — Apple's echo cancellation on the mic (default off).
  Set `true` when recording meetings through the speakers, so playback doesn't
  bleed into the mic track and get transcribed twice as "me". The trade: while
  the voice unit is live, macOS ducks other playback slightly (`.min` ducking
  is configured, but it can't be zeroed). On headphones there's no echo to
  cancel, so raw capture is the better default.
- `transcript_echo_filter` — remove mic words that duplicate overlapping
  system speech (default on). Keep it on for laptop-speaker calls; it is a
  no-op when the mic does not contain system playback.
- `on_stop` — shell command spawned with the session directory as its
  argument, **after the transcript is written** (or right after recording if
  transcription is disabled). Wire it to whatever comes next: summarization,
  filing, indexing.

## CLI

```sh
quill                        # run the menu-bar daemon (^C to quit)
quill run --out <dir>        # custom recordings root (default ~/Recordings)
quill run --start-recording  # launch the tray and begin immediately
quill record --seconds 10    # one-shot recording for scripts / smoke tests
quill doctor                 # check permissions, recordings folder, models
quill install --launch-at-login
quill install --uninstall
```

## Stack

- **Swift** — single SPM executable target
- **Core Audio process tap** (`AudioHardwareCreateProcessTap`, macOS 14.2+) —
  system audio capture via a private aggregate device
- **AVAudioEngine** — mic capture
- **AVAudioFile** — streaming AAC encode into CAF
- **FluidAudio / Parakeet** — on-device Core ML transcription
- **NSStatusItem** — the whole UI

## Licensing and public forks

The source remains MIT and preserves the upstream copyright notice. See
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) and
[`MODEL_NOTICES.md`](MODEL_NOTICES.md); the installer copies the full required
license texts into the app bundle.

This is an independent fork and is not affiliated with Andrew Jones,
Quill Notes, NVIDIA, FluidInference, or Lucide. Before a public
release, use a new clearance-checked product name: another Mac meeting
recorder already uses the `Quill` name. See [`ROADMAP.md`](ROADMAP.md).

Recording laws and workplace policies vary. Obtain any consent required for
recording, transcription, or cloud processing, and protect recordings and
transcripts as sensitive data.

## Gotchas

- A global tap records *everything* the Mac plays — notification dings,
  music, all of it. Don't play Spotify during meetings (or ask for a
  per-process picker if it bothers you).
- If recordings come out silent, check System Settings → Privacy & Security →
  Screen & System Audio Recording.
- macOS can hide status items when the right side of a notched menu bar is
  full. Quill uses a compact square item; if it is still absent, hide or move
  one existing menu extra to make room.
- A Focus can silence an otherwise authorized notification. Add Quill to
  **Allowed Apps** for each Focus in which transcript-ready banners should
  appear; macOS does not let an app grant itself that exception.
- The binary embeds its Info.plist (`__TEXT,__info_plist`) so TCC can
  attribute permissions to quill itself when running as a LaunchAgent.
