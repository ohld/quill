# Product roadmap

The current release intentionally solves one job first: press Record on a Mac,
capture clean mic and system tracks, stop, and receive one role-labelled text
file at `~/Recordings/latest-transcript.md`.

## Ready now

- Compact menu-bar control with a red recording state and live source health.
- Five-second completion popover with a direct Finder action.
- Separate microphone and system-audio tracks.
- Local multilingual Parakeet v3 engine plus optional Spokenly batch engine.
- `me` / `remote` role attribution, timestamp merge, acoustic-echo filtering,
  readable Markdown, canonical timed JSON, retry queue, and stable latest file.

## Next: trustworthy call assistance

- Detect likely Meet, Zoom, and Telegram calls from app/window state plus audio
  activity; suggest starting rather than silently recording.
- After 60–90 seconds of silence on both tracks, suggest stopping. Never stop
  solely because a speech detector is uncertain.
- Add drift correction for long calls, a mic input limiter, and local
  diarization of the system track when several remote people speak.
- Restart the microphone track after input-device changes and warn when either
  capture stream stalls instead of silently producing an incomplete recording.
- Keep a confidence-scored participant timeline. Platform names are hints;
  never assign a human name to a voice merely by roster order.

## Later: optional live text

- Add a separate `LiveTranscriptProvider` for provisional captions, with an
  explicit cloud/offline indicator and user consent.
- A direct Soniox BYOK provider is feasible. Spokenly exposes Soniox for its
  own dictation UI, but its public CLI only supports batch file transcription.
- Always regenerate the canonical post-call transcript from original tracks
  with the chosen final engine; provisional captions never overwrite it.

## Platform constraints

- Meet DOM and accessibility state can expose call controls and sometimes
  participant hints, but selectors are not a stable identity API.
- Zoom participant/active-speaker data requires an installed Zoom App and can
  depend on host/co-host privileges.
- Telegram participant speech state requires a separate authenticated TDLib
  client; app process/audio activity alone cannot reveal a person's name.

## Public release gate

Before publishing source or binaries:

1. Rename the product, executable, bundle identifiers, config paths, and
   LaunchAgent after a name-clearance check. `Quill` is already used by another
   Mac meeting-recorder product; `Quill RU` is not sufficient differentiation.
2. Preserve upstream authorship and ship all files listed in
   `THIRD_PARTY_NOTICES.md` inside the app bundle.
3. Add recording-consent and sensitive-data guidance.
4. Verify the archived `.app` contains license resources and that no model or
   proprietary Spokenly binary is bundled.
5. Publish from a non-placeholder contributor identity.
