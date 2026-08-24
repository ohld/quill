# Quill project context

Quill is currently a private, personal macOS menu-bar tool. Its one job is to
turn a manually started call recording into one local, role-labelled Markdown
transcript with no file shuffling or cloud transcription dependency.

## Domain language

- **Recording session** — one timestamped folder containing the audio and all
  derived artifacts for one call.
- **Mic track** — the local participant (`speaker_names.mic`).
- **System track** — remote speech played by the Mac
  (`speaker_names.system`). Several remote people may still share this role.
- **Finalized session** — both audio writers are stopped and an atomic
  `meta.json` marker exists. Only finalized sessions enter transcription.
- **Canonical transcript** — `transcript.json`; `transcript.md` and
  `latest-transcript.md` are readable projections.

## Invariants

1. Mic and system audio stay separate through recognition, then merge on the
   timestamp offsets stored in metadata.
2. `stop()` returns only after callbacks are quiescent and AAC files are
   finalized. Metadata errors are surfaced; an incomplete session is never
   enqueued as complete.
3. The filesystem is the durable queue: finalized sessions without
   `transcript.json` retry after launch.
4. Every dequeued session produces its own success or failure outcome. Queue
   progress is a separate concept and cannot stand in for a session result.
5. One immutable configuration snapshot is used for the process lifetime.
6. Final transcription is built-in FluidAudio Parakeet v3 and stays local.
   There is no Spokenly or other external transcription backend.
7. Native notification and tray fallback are mutually exclusive. Finder and
   copy-path actions target the immutable `transcript.md` inside the exact
   completed session, never the mutable `latest-transcript.md` projection.

## Product boundaries

- Manual tray start/stop is the primary control path. Native Meet/Zoom presence
  detection may offer those same actions, but never invokes them automatically.
- Silence detection may suggest stopping only as a fallback, and must never
  stop automatically.
- Live captions and participant-aware platform integrations are future opt-in
  features; they cannot replace the canonical local post-call transcript.
- The current name and feather branding are acceptable for private use and for
  source published explicitly as an experimental fork. Rebranding product
  namespaces remains a gate before distributing or marketing an independent
  binary; see `PUBLISHING.md` and `ROADMAP.md`.
