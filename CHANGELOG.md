# Changelog

## [0.1.1] - 2026-10-31

### Fixed

- Fix garbled or doubled words at 15-second window overlaps in long
  transcripts by updating FluidAudio to 0.18 (Parakeet TDT v3 unchanged).
- Finalize the mic file before stopping the audio engine, so a blocking
  engine stop can no longer leave the mic track unfinalized.
- Keep recording the microphone across route changes (Bluetooth headset
  connect/drop, default input switch): a stall watchdog restarts capture,
  resamples the new route into the same file and pads the gap so mic
  timestamps stay aligned. Previously the mic track stopped for the rest of
  the session. An empty mic track is now logged at stop.

### Changed

- Add a "Made by okhlopkov.com" menu item and capitalize "Quit Quill".
- Use one Info.plist for the app bundle and the embedded binary identity.
- README: terminal install, `quill doctor`, uninstall, build-from-source
  requirements and the `on_stop` hook. Upstream links now point to
  humanitas-labs/quill; publishing notes moved to `docs/`.

### Transcription worker

- Release native speech-recognition memory when the queue drains by running
  Parakeet in a local worker process shared by both audio tracks.
- Fix an owned Core Audio string leak in the idle call detector.
- Preserve unfinished sessions for retry after a transcription worker crash.
- Add worker-lifecycle, dual-track speech and opt-in idle-memory checks.

## [0.1.0] - 2026-08-24

### Added

- Downloadable Apple Silicon menu-bar app with an automated tag-based GitHub Release pipeline.
- Local multilingual Parakeet v3 transcription, including Russian and English.
- Separate microphone and system-audio tracks merged into one role-labelled transcript.
- Native Meet and Zoom start/stop suggestions without a browser extension.
- Transcript-ready notifications with Finder and exact-session path-copy actions.

### Changed

- Reworked recording finalization, retry handling, metadata, source-health reporting, and transcript formatting for dependable daily use.
- Kept all audio, model inference, and transcripts local to the Mac.
