# Changelog

## Unreleased

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
