# Configuration and secrets

## Public build configuration

| Name | Used by | Source | Change/rotation | Risk |
| --- | --- | --- | --- | --- |
| `com.daseanle.votype` | Main app/signing | `project.yml`, workflow | New App ID and store record required to change | Bundle mismatch breaks install/upload |
| `com.daseanle.votype.keyboard` | Extension/signing | `project.yml`, workflow | New extension App ID/profile required | Nested signing or App Group IPC fails |
| `group.com.daseanle.votype.container` / `APP_GROUP` | App, extension, CI checks | entitlements, Swift, workflow | Change all targets, IDs and profiles together | Partial change silently breaks IPC |
| `R765X25892` / `TEAM_ID` | Xcode signing and profile validation | `project.yml`, workflow | Change only with Apple team migration | Wrong team invalidates signatures |
| `MARKETING_VERSION` / `APP_VERSION` | Bundle/store version | `project.yml`, workflow | Release decision | Must match App Store version |
| `CI_BUILD_NUMBER` | `CFBundleVersion` | GitHub run number | Automatic, immutable per run | Duplicate number is rejected by Apple |

## GitHub Actions secrets

| Name | Used by | Source/scope | Rotation | Risk |
| --- | --- | --- | --- | --- |
| `DIST_CERTIFICATE_P12` | Distribution build | GitHub Actions secret | Replace before certificate expiry/after compromise | Can sign App Store packages for this team |
| `DIST_CERTIFICATE_PASSWORD` | P12 import | GitHub Actions secret | Rotate with P12 | Exposes private key if paired with P12 |
| `ASC_KEY_ID` | Fastlane API auth | GitHub Actions secret | Revoke/replace in App Store Connect | Identifies API key |
| `ASC_ISSUER_ID` | Fastlane API auth | GitHub Actions secret | Changes with issuer/account | Account association |
| `ASC_KEY_CONTENT` | Fastlane API auth | Base64 private key in Actions secret | Revoke immediately after compromise | Can perform the API key role's store actions |
| `CERTIFICATE_P12` | Optional development build | GitHub Actions secret | Replace before expiry/compromise | Development signing |
| `CERTIFICATE_PASSWORD` | Development P12 import | GitHub Actions secret | Rotate with P12 | Exposes development key if paired |
| `PROVISIONING_PROFILE_APP` | Optional development build | GitHub Actions secret | Regenerate after capability/cert/device changes | Stale profile disables capabilities |
| `PROVISIONING_PROFILE_KEYBOARD` | Optional development build | GitHub Actions secret | Same as above | Stale profile breaks extension/App Group |

No secret is stored in the repository or bundled in either client target. CI
writes the App Store API JSON, P12 material and keychain only into runner-temp
locations, masks generated passwords, and deletes the keychain/key file in the
always-run cleanup step.

## Pre-go-live configuration check

- Confirm both Apple App IDs and both active profiles contain the exact App Group.
- Confirm one valid Apple Distribution identity is imported into the isolated keychain.
- Confirm App Store Connect API role is the minimum role that can upload builds/metadata.
- Confirm the generated main and extension signatures match the certificate,
  Team ID, Bundle IDs, embedded profile UUIDs and App Group.
- Confirm the generated Info.plist validator passes before upload.
- Revoke unused/old API keys and certificates; never paste their values into an issue or document.
