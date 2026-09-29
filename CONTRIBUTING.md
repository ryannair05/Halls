# Contributing to Halls

Start with the root README to build the platform you want to change. Keep changes focused and explain the problem, the resulting behavior, and how you verified it. For significant features, discuss the proposed behavior with the maintainers before investing in a large change.

- Follow the existing Swift/Objective-C or Kotlin conventions and preserve iOS 17 / Android API 31 support.
- Keep slow work off the UI thread. Respect platform-specific feature and campus differences.
- Preserve third-party notices and avoid unrelated changes to vendored BTChat.
- Keep private configuration, generated files, and signing material out of commits. Check `git diff --cached` before submitting.
- Add regression tests where they meaningfully exercise changed behavior. Avoid tests that merely repeat trivial implementation details.

For Android, run `./gradlew :app:assembleDebug :app:testDebugUnitTest` from `android/`. Some provider tests may depend on live network availability; report that separately from deterministic failures.

For iOS, build the app and widget with the shared Penn State Meals scheme. There is no iOS test target in this snapshot. Verify changed interactions on a simulator or device when appropriate, including the configuration-free startup path for service changes.

Contributions to project-owned code are submitted under AGPL-3.0-only. Preserve the original license of third-party material and identify the source of any new external assets or code.
