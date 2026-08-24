# Publishing and release policy

## Current decision

Publish this repository as a clearly attributed GitHub fork of
[`digimata/quill`](https://github.com/digimata/quill). Keep the Quill name and
feather only while it is presented as an experimental community fork. Daniil
Okhlopkov's changes remain under the upstream MIT license.

The release archive is a convenience build for Apple Silicon, not a separately
marketed product. Before turning it into an independent product, choose a new
clearance-checked name and update the executable, bundle ID, LaunchAgent, config
paths, icon, and user-facing copy together.

## What ships

- Source with the complete upstream history and MIT notice.
- `Quill-arm64.zip` built from a version tag by GitHub Actions on macOS 14.
- `SHA256SUMS.txt` for the release archive.
- All required dependency, icon, and model notices in source; complete bundled
  dependency license texts inside `Quill.app`.

Model weights and user recordings are never included. Parakeet model weights
download on first transcription and remain subject to their own CC BY 4.0 notice.

## Signing status

The current release is ad-hoc signed and validated with `codesign --verify`; it
is not Apple-notarized. Users must try opening it once, then allow it through
**System Settings → Privacy & Security → Open Anyway**. Because the public
signature is bound to each binary hash, later ad-hoc updates may request
Microphone and System Audio Recording permissions again.

For a frictionless public install, configure all of the following:

1. Apple Developer Program membership and a Developer ID Application certificate.
2. Hardened-runtime signing in the release workflow.
3. Apple notarization and stapling before the archive is uploaded.
4. Verification on a second clean macOS 14.2+ Apple Silicon Mac.

Never describe an ad-hoc build as Apple-signed or notarized.

## Fork and trademark boundary

The MIT license permits use, modification, publication, and binary distribution
when its copyright and license notice remain included. It does not grant rights
to imply endorsement or remove third-party notices. Another meeting product uses
the Quill name, so this repository must remain visibly labelled as an unofficial
fork until it is rebranded.
