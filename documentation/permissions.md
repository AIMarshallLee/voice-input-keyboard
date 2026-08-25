# Permissions and access matrix

VoType has no login, remote roles, access tokens, server database or row-level
security. Device-owner consent and Apple platform entitlements are the access
control system.

## Principals and scope

| Principal | Scope source | Capabilities |
| --- | --- | --- |
| Device owner | iOS permission settings and direct gestures | Enable keyboard, Full Access, mic/Speech, PiP, start/stop sessions, delete local data |
| Keyboard extension | Signed extension entitlement + Full Access | Read/write the VoType App Group, insert text through `textDocumentProxy` |
| Containing app | Signed app entitlement + mic/Speech authorization | Read/write App Group, record user-initiated audio, request Speech recognition |
| iOS | Platform policy | Grant/revoke permissions, suspend processes, display PiP and mic indicators |
| GitHub maintainer | Repository/Actions permissions | Manually dispatch a distribution job and manage secrets |
| App Store Connect API key | Apple issuer/key role | Upload binary and optional metadata; role is configured outside the repo |

## Resource matrix

| Resource / operation | User | Keyboard | App | CI maintainer | Deny behavior |
| --- | --- | --- | --- | --- | --- |
| Local Pinyin/English typing | Uses | Read/insert | None | None | Remains available without voice permissions |
| App Group preferences | Controls via UI | Read/write | Read/write | None | Voice/settings sync unavailable without valid entitlement/Full Access |
| Session files | Starts/cancels | Create/read/consume | Consume/write | None | UUID, freshness, cancellation and context checks reject misuse |
| Microphone | Grants and starts | Never | Use during active session | None | Explicit error; no fake listening state |
| Apple Speech | Grants and starts | Never | Submit recognition request | None | Error or unavailable state; no developer-server fallback |
| PiP standby | Explicit start/stop | Read readiness only | Start/stop visible PiP | None | Readiness cleared immediately and expires in 3.5 seconds |
| Local model | Enables processing through settings/session | Supplies session setting | User text in, string out | None | Availability/length guard returns original/local result |
| Signing material | None | None | None | Use in isolated runner | Publish job fails if absent or mismatched |
| App Store upload | None | None | None | Manual dispatch only | No dispatch means no upload; no review submission exists |

## Platform declarations

- Both products declare only the App Group entitlement.
- The app declares microphone and Speech usage descriptions and `audio` as the
  valid Audio/AirPlay/PiP background mode.
- The keyboard declares `RequestsOpenAccess=true`; the onboarding and privacy
  policy explain why.
- Both products include Privacy Manifests declaring no tracking/collected data
  and the approved UserDefaults required-reason API.

