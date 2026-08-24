# Product roadmap

The current release intentionally solves one job first: press Record on a Mac,
capture clean mic and system tracks, stop, and receive one role-labelled text
file at `~/Recordings/latest-transcript.md`.

## Ready now

- Compact menu-bar control with a red recording state and live source health.
- Native browser-based Meet and Zoom call-presence suggestions from application
  windows plus per-process input/output stream state. Suggestions never start
  or stop recording automatically.
- Native completion notification with Finder and exact-session path-copy
  actions, plus a five-second tray fallback when alerts are unavailable.
- Separate microphone and system-audio tracks.
- Local multilingual Parakeet v3 transcription with no external service.
- `me` / `remote` role attribution, timestamp merge, acoustic-echo filtering,
  readable Markdown, canonical timed JSON, retry queue, and stable latest file.

## Next: trustworthy call assistance

- Extend call detection to Telegram and additional browsers after real-call
  traces establish trustworthy platform-specific signals.
- Use 60–90 seconds of silence on both tracks only as a fallback stop
  suggestion when native call lifecycle detection is unavailable. Never stop
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
- A direct Soniox BYOK provider is feasible if live captions ever justify a
  clearly opt-in cloud path.
- Always regenerate the canonical post-call transcript from original tracks
  with the chosen final engine; provisional captions never overwrite it.

## Platform constraints

- Meet DOM and accessibility state can expose call controls and sometimes
  participant hints, but selectors are not a stable identity API.
- Zoom participant/active-speaker data requires an installed Zoom App and can
  depend on host/co-host privileges.
- Telegram participant speech state requires a separate authenticated TDLib
  client; app process/audio activity alone cannot reveal a person's name.

## Public fork and releases

Current decision: publish this as a GitHub-network fork of `digimata/quill`
with a tested Apple Silicon archive. Keep the fork relationship, attribution,
license notices, recording-consent warning, and signing status visible.

Next release work:

1. Add Developer ID signing, hardened runtime, notarization, and stapling.
2. Verify the download and first-call flow on a second clean Apple Silicon Mac.
3. Add a current tray/notification screenshot and a short demo recording.

## Independent product gate

The following is mandatory before presenting the project as an independent
product rather than an explicitly attributed community fork.

1. Rename the product, executable, bundle identifiers, config paths, and
   LaunchAgent after a name-clearance check. `Quill` is already used by another
   Mac meeting-recorder product; `Quill RU` is not sufficient differentiation.
2. Preserve upstream authorship and ship all files listed in
   `THIRD_PARTY_NOTICES.md` inside the app bundle.
3. Add recording-consent and sensitive-data guidance.
4. Keep verifying that the archived `.app` contains license resources and that
   model-license requirements are met.
5. Publish from a non-placeholder contributor identity.
