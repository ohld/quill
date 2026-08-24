# Publishing assessment

Status: prepared for a future source-only publication; repository visibility
must stay private until the owner explicitly changes it.

## Recommendation

Publish the current repository first as an **experimental multilingual fork of
[`digimata/quill`](https://github.com/digimata/quill)**, without a downloadable
binary. Do not rebuild the repository merely to make GitHub display a `fork`
badge: `ohld/quill` is currently a standalone private repository, but its Git
history already descends from upstream and the README/license notices make the
relationship explicit.

The upstream MIT license permits use, modification, and publication as long as
its copyright and permission notice remain included. This repository preserves
that notice in `LICENSE`, adds contributor ownership in `COPYRIGHT`, and records
dependency/model attribution separately.

Keep `Quill` only as the clearly labelled source-fork name for now. Before
shipping an independent app or marketing a product, choose a new name and
rename the executable, app bundle, bundle ID, LaunchAgent, config path, status
item identity, icon, and user-facing text together. A commercial local meeting
assistant named Quill already exists, so `Quill RU` is not enough separation.

## What is ready

- Full upstream history and MIT notice are present.
- Fork modifications have an explicit contributor copyright notice.
- FluidAudio, model, transitive dependency, and icon notices are documented.
- Recordings, cached model weights, configuration, and credentials are outside
  the repository; the tracked history is small and contains no media files.
- README now explains the fork's concrete multilingual and macOS additions.

## Before changing visibility

1. Merge the chosen release branch into the default branch and push it.
2. Change the GitHub description; it currently mentions Spokenly, which is no
   longer part of the application.
3. Review whether placeholder `skill-ci@example.com` author entries in private
   WIP commits are acceptable. Rewriting them is optional and history-changing.
4. Run a dedicated full-history secret scanner in addition to the completed
   manual filename/content audit.
5. Add a current screenshot or short GIF showing idle, recording, source
   health, and the completed-transcript notification.
6. Confirm the README install steps on a second macOS 14.2+ Apple Silicon Mac.
7. Keep the first public release source-only. Add signed/notarized binaries only
   after the separate product-name, signing, update, and bundled-license checks.

Changing visibility publishes the entire repository and its past commits, not
just the current tree. It also makes the code forkable by anyone. Treat the
visibility toggle as the final, explicit owner action rather than an install or
build step.

## References

- [MIT License (Open Source Initiative)](https://opensource.org/license/mit)
- [Changing repository visibility (GitHub Docs)](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/setting-repository-visibility)
- [GitHub fork visibility rules](https://docs.github.com/en/pull-requests/reference/forks)
- [Existing Quill meeting assistant](https://www.quillmeetings.com/docs/introduction)
