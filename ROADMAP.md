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

## Public source gate

Current decision: keep this repository private and optimize it for personal
daily use until the owner explicitly changes visibility. The source can later
be published under MIT as an explicitly attributed experimental derivative of
`digimata/quill`; it does not need to be reconstructed as a GitHub-network
fork first because the upstream ancestry is already preserved.

Before changing repository visibility:

1. Merge the intended release branch into the default branch and update the
   GitHub description, which still mentions the removed Spokenly backend.
2. Review the complete Git history and run an automated secret scan, because
   making a private repository public exposes past commits as well as current
   files.
3. Keep `LICENSE`, `COPYRIGHT`, `THIRD_PARTY_NOTICES.md`, and
   `MODEL_NOTICES.md`; describe the project prominently as a fork.
4. Add one current tray/notification screenshot and a short tested install
   path before inviting other users.

## Independent product/binary gate

The following is mandatory before distributing a downloadable `.app` or
presenting the project as an independent product rather than a source fork.

1. Rename the product, executable, bundle identifiers, config paths, and
   LaunchAgent after a name-clearance check. `Quill` is already used by another
   Mac meeting-recorder product; `Quill RU` is not sufficient differentiation.
2. Preserve upstream authorship and ship all files listed in
   `THIRD_PARTY_NOTICES.md` inside the app bundle.
3. Add recording-consent and sensitive-data guidance.
4. Verify the archived `.app` contains license resources and that model-license
   requirements are met.
5. Publish from a non-placeholder contributor identity.
