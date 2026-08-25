# Release, signing, archive and rollback runbook

## Candidate identity

- Marketing version: `1.0`
- Build number: GitHub Actions run number supplied as `CURRENT_PROJECT_VERSION`
- Source identity: full `main` commit SHA
- Bundle IDs: `com.daseanle.votype`, `com.daseanle.votype.keyboard`
- App Group: `group.com.daseanle.votype.container`

Every candidate evidence record must include version/build, commit, Actions run,
test counts, artifact ID/digest, signing checks, App Store processing state and
real-device status. Use `documentation/releases/` for immutable records.

## Build and sign

1. Merge only after PR CI passes.
2. Wait for a fresh `main` run to pass generated Info.plist validation, unit/UI
   tests, generic iphoneos Release build, unsigned `.xcarchive`, IPA packaging
   and artifact upload.
3. Manually dispatch **Build IPA** on `main` with `publish=true` and
   `upload_metadata=false`.
4. CI must create/validate the two App Store profiles, verify exact Team/Bundle/
   App Group/signers/profile UUIDs, sign the nested extension and main app, and
   upload a versioned App Store IPA artifact.
5. Confirm App Store Connect processing and internal tester availability. Do not
   infer this from only a successful HTTP upload.
6. Install that exact build and complete the final-device matrix.
7. Replace and approve real screenshots; validate metadata and privacy answers.
8. Only after the owner explicitly approves, perform the manual App Review
   submission in App Store Connect. This repository does not automate review.

## Archive evidence

GitHub Actions IPA artifacts are retained for 30 days. Before expiry, the owner
should download the signed IPA and archive it in an access-controlled release
store together with:

- Actions log bundle and artifact SHA-256;
- source commit/tag and `project.yml`;
- export/signing verification output without keys, passwords or profiles;
- final device checklist and approved screenshots;
- App Store Connect processing/build identifier.

Never archive private keys, API key content or certificate passwords with the
public repository evidence.

## Rollback

| Failure point | Action |
| --- | --- |
| Before App Review | Stop internal distribution, keep the build unsubmitted, fix on a new commit/build |
| During review | Remove the build from review in App Store Connect; do not reuse its build number |
| After approval but before release | Cancel/hold the release and select a known-good build if Apple permits |
| After public release | Stop phased release if active; submit a higher-build hotfix based on the last known-good tag |
| Compromised key/certificate | Cancel workflows, revoke in App Store Connect/Developer, replace Actions secrets and regenerate profiles |
| PiP/review rejection | Do not disguise behavior; remove or redesign the standby capability on a new branch and resubmit with updated metadata |

Rollback never uses `git reset --hard` on shared history and never overwrites an
already uploaded build. Use a revert/new commit and a new build number.
