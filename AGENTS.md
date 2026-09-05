# VoType development instructions

## Scope and continuation

- This repository is the VoType / 声入 iOS voice keyboard, not the surrounding Obsidian workspace.
- Resume from `documentation/delivery-status.md`, the current approved spec and its implementation plan. Current work is Slice A only.
- Active implementation checkout: `D:/Obsidian/voice-input-keyboard/.worktrees/slice-a`, branch `codex/slice-a-reliable-session-engine`, draft PR #13. Verify these facts before acting; do not implement in both checkouts.
- Preserve other contributors' changes. The parent owns Git/CI/merge/release; workers own only their assigned files. Do not spawn redundant implementation or review agents.
- Use the lowest reliable execution tier and independent review for IPC, concurrency, editor safety and distribution. Keep test-only utilities out of production code.

## Sources and commands

- `project.yml` is the only XcodeGen configuration source. Do not commit generated `.xcodeproj`, `.xcworkspace`, Info.plist or build artifacts.
- Minimum iOS is 16.0; Swift remains 5.9. Do not upgrade dependencies or deployment targets as incidental cleanup.
- Generate on macOS: `xcodegen generate`.
- Unit tests: `xcodebuild test -project VoType.xcodeproj -scheme VoTypeTests -destination "platform=iOS Simulator,id=$SIM_ID" CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION="$PLAN_BUILD_NUMBER" -derivedDataPath ./slice_a_test_build`.
- UI smoke: same command with scheme `VoTypeUITests` and derived data `./slice_a_ui_test_build`.
- Establish `SIM_ID` and `PLAN_BUILD_NUMBER` with the current plan's Execution Conventions. Release/archive commands and content checks are in that plan and `.github/workflows/build.yml`; do not invent Windows equivalents.
- Cross-platform plist gate: `python3 -m unittest scripts.tests.test_validate_distribution_info`.
- Check patch whitespace: `git diff --check` (also check staged files before commit).
- CI is `.github/workflows/build.yml`, using `macos-26`. PR events, main pushes and manual dispatch trigger it; arbitrary development-branch pushes alone do not.
- Windows lacks Apple SDK/Xcode; missing runtime is NOT a passing test or expected TDD failure. Use the PR CI and preserve exact SHA/run evidence.

## Invariants and completion

- Follow test-first sequencing: observe the expected failure on macOS before production implementation; then run relevant suites and task review.
- One actor owns permission/audio/Speech/deadline/terminal state; adapters must not retain duplicate recorders after migration.
- Audio buffers append synchronously behind a close barrier; no Swift Task per PCM buffer.
- UUID session identity crosses IPC; actor generation never does. Terminal, cancellation and consumption stay idempotent and replay-safe.
- Manual or ambiguous results require explicit action; never bypass selection/context validation or silently delete user text.
- No unsupported keyboard-to-containing-app launch in the completed Slice A distribution. No raw audio persisted, credentials logged or user text added to diagnostics.
- Task completion requires relevant fresh tests and review; Slice A additionally requires 50-session/race gates, UI smoke, source gate, unsigned Release and archive containing app plus extension.
- Real microphone, PiP, extension eviction and third-party input remain external device gates. CI/IPA/TestFlight processing never substitutes for them.

## Current authority

- On 2026-09-05 the user explicitly authorized project-isolated branches/worktrees, commits, non-force pushes, PR/macOS CI and main merge, including necessary credential operations and TestFlight/App Store distribution operations.
- Authorization does not waive review or release gates. Do not merge unfinished Slice A or release a failed candidate. Credential handling must have a concrete need; never expose secrets.
- Preserve the user's requirement to confirm App Store submission after real-device acceptance. TestFlight is a test-delivery channel, not final acceptance.
- No recurring heartbeat is enabled by this authority; do not claim execution continues after the turn without a real trigger.
- Record all results and blockers in the delivery ledger; the plan-scoped `.superpowers/sdd/` scratch ledger is a recovery aid, not proof by itself.
