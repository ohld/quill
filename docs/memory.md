# Memory lifecycle

Recording streams microphone and system audio to separate files. FluidAudio
0.15.5 reads tracks longer than 30 seconds through disk-backed conversion;
there is no retained hour-long PCM buffer in Quill's recording session.

On macOS 14.7.8 / M1 Pro / 16 GB, the original in-process Parakeet lifecycle
still retained 1,629 and 1,660 MiB after two successive 60-second synthetic
transcriptions and `release()`, versus a 7 MiB baseline. Repeating with the
entire detached task completed and ten seconds to settle left 1,602 / 1,623
MiB. `vmmap` showed most of the retained footprint in malloc regions.
Allocator pressure relief still left over 1.2 GiB, so it is not a sufficient
fix. These observations establish retention in the native ASR process, not
which private Core ML allocation owns every byte.

Quill uses a separate local worker for recognition. One worker loads the same
Parakeet v3 model and GPU configuration, processes both tracks and subsequent
queued sessions, then exits when the queue drains. The tray waits for worker
exit before reporting idle, reclaiming the native runtime's allocations along
with model objects. Only file paths and timed transcript segments cross the
local pipes. Speaker mapping, offsets, echo filtering, transcript writes and
hooks remain in the coordinator. Audio and transcripts stay local.

This intentionally trades the native runtime's warm in-memory state between
separate batches for low idle memory. It does not claim faster recognition;
model loading can take several seconds at the next batch. The existing model
cache on disk is retained.

The idle call detector also releases the owned CFString returned by Core
Audio's `kAudioProcessPropertyBundleID`. The local SDK's `AudioHardware.h`
explicitly makes that the caller's responsibility; omitting the release leaked
one returned reference per audio process on each one-second poll.

## Verification

- On the same Mac, two one-minute worker cycles returned to 8 / 8 MiB in the
  parent. Two one-hour synthetic cycles returned to 7 / 8 MiB, taking 70.3 /
  66.8 seconds including loading, IPC, cleanup and a two-second settling wait.
  This is an idle-memory measurement, not a recognition-speed benchmark or a
  claim about model memory during inference.
- Real local speech synthesized by macOS was recognized through both tracks;
  the canonical transcript retained `me` / `remote` and the system offset.
- A parent-death probe kept the input pipe open, terminated the parent, and
  verified the worker exited and removed its own temporary audio directory.
- `swift test` exercises queue cleanup ordering, arrivals during cleanup and
  worker transport/failure handling without loading models.
- `QUILL_ASR_MEMORY_TEST=1 swift test --filter ParakeetMemoryTests` runs two
  synthetic one-minute recognition cycles and checks post-release physical
  footprint. It uses the adjacent built `quill` executable and removes its
  generated audio on exit. The real-model test is opt-in because it can load
  or download the existing Parakeet model.
- Add `QUILL_ASR_TEST_SECONDS=3600` to exercise an hour-long track.
- Add `QUILL_ASR_IN_PROCESS=1` to reproduce the old lifecycle using the same
  fixture. This is expected to fail the idle-memory budget on the affected Mac.

Physical footprint is measured with `TASK_VM_INFO.phys_footprint`, comparable
to macOS memory accounting. RSS and virtual address-space size are different
metrics and must not be compared to it as if they were the same.
