# Quill — local multilingual meeting transcription for macOS

An unofficial fork of [digimata/quill](https://github.com/digimata/quill),
adapted by [Daniil Okhlopkov](https://github.com/ohld) for Russian and
multilingual calls.

Quill lives in the menu bar. Start a recording, finish the call, and receive
one local Markdown transcript with `me` / `remote` roles. Audio and speech
recognition stay on your Mac.

[Download Quill for Apple Silicon](https://github.com/ohld/quill/releases/latest/download/Quill-arm64.zip)
· [Latest release](https://github.com/ohld/quill/releases/latest)
· [Original project and technical README](https://github.com/digimata/quill)

## What this fork adds

- Multilingual Parakeet TDT 0.6B v3 transcription, including Russian and English.
- A compact menu-bar app with a red recording indicator and source-health status.
- Separate microphone and system-audio tracks, merged by time into one transcript.
- Native transcript-ready alerts with **Open in Finder** and **Copy Full Path**.
- Meet and Zoom start/stop suggestions using macOS signals, without a browser extension.
- Durable local transcription queue, readable Markdown, timed JSON, and acoustic-echo filtering.

## Install

Requires **macOS 14.2+ on Apple Silicon**.

1. [Download `Quill-arm64.zip`](https://github.com/ohld/quill/releases/latest/download/Quill-arm64.zip).
2. Unzip it and move `Quill.app` to `/Applications`.
3. Try to open Quill once. If macOS blocks it, open **System Settings → Privacy
   & Security**, scroll to Security, choose **Open Anyway**, then confirm **Open**.
4. Allow Microphone, System Audio Recording, and Notifications when macOS asks.

The public build is ad-hoc signed because this fork does not yet have an Apple
Developer ID certificate. It is verified by CI but not notarized by Apple, so a
normal double-click may be blocked on first launch. Because an ad-hoc identity
changes between releases, an update may also ask for capture permissions again.
Future builds can become one-click installs with stable permissions once
Developer ID signing and notarization are configured.

To build from source instead:

```sh
./Scripts/install-app.sh
```

This installs `~/Applications/Quill.app` and registers it to launch at login.

## Use

1. Click the feather in the menu bar and choose **Start recording**.
2. Confirm that both **Microphone** and **System audio** become active.
3. Choose **Stop recording** when the call ends.
4. Quill transcribes both tracks locally. The notification can reveal the exact
   transcript in Finder or copy its immutable full path.

Each call is stored separately:

```text
~/Recordings/2026.08.24-1530/
├── mic.caf
├── system.caf
├── meta.json
├── transcript.json
├── transcript.md
└── transcribe.log
```

`mic.caf` is your microphone; `system.caf` is the sound played by the Mac.
Transcribing them separately gives reliable two-role separation without asking
a diarization model to guess who is local. The first transcription downloads
the Parakeet Core ML model; later transcription is fully local.

Quill may suggest starting when it detects an active Meet or Zoom call and
stopping when the call's audio streams close. These are suggestions only. It
never starts or stops recording automatically.

## Optional config

Create `~/.config/quill/config.json` only if you want to change defaults:

```json
{
  "recordings_dir": "~/Recordings",
  "speaker_names": { "mic": "Dan", "system": "Remote" },
  "transcript_echo_filter": true
}
```

## Notes

- A system tap captures everything the Mac plays, including notification sounds.
- A browser exposes audio per application, not per tab. Meet detection therefore
  combines a Meet-titled window with active browser audio streams.
- A Focus can hide transcript notifications. Add Quill to that Focus's Allowed Apps.
- Recording and transcription laws vary. Obtain any consent your jurisdiction or
  workplace requires and protect recordings as sensitive data.

## License and upstream

This fork remains under the upstream [MIT license](LICENSE) and preserves Andrew
Jones's copyright notice. Fork changes are copyright Daniil Okhlopkov and their
respective contributors. See [COPYRIGHT](COPYRIGHT),
[third-party notices](THIRD_PARTY_NOTICES.md), and
[model notices](MODEL_NOTICES.md).

Quill is an experimental community fork, not an official release of the original
project and not affiliated with Andrew Jones, NVIDIA, FluidInference, Lucide, or
other products using the Quill name. For the original architecture and technical
background, read the [upstream README](https://github.com/digimata/quill#readme).
