# App Store metadata and screenshot checklist

## Source files

| Material | Location | Status before submission |
| --- | --- | --- |
| Localized description/name/subtitle/keywords | `fastlane/metadata/{zh-Hans,en-US}` | Review against final device build |
| Privacy policy | `docs/privacy-policy.html` | Must return 200 and match binary |
| Support page | `docs/support.html` | Must return 200 |
| Reviewer notes/test steps | `docs/appstore-metadata.md` | Copy only after final device pass |
| Screenshots | `fastlane/screenshots/{zh-Hans,en-US}` | Historical placeholders; replace all |
| License/notices | `LICENSE`, `THIRD_PARTY_NOTICES.md`, lexicon license files | Present |

## Accuracy gate

Do not claim automatic language detection, universal/offline recognition,
unlimited duration, guaranteed containing-app launch, guaranteed no App switch,
developer-hosted AI, or App Review acceptance. Foundation Models features must
say iOS 26+ supported device. In-place voice must say the user first enables
the visible standby and that iOS may still end it.

## Screenshot capture list

Capture from the exact processed candidate on physical devices after clearing
old data. Required story, in both Simplified Chinese and English:

1. First-run keyboard, Full Access and mic/Speech setup.
2. Real Chinese Pinyin candidate keyboard and English mode.
3. Visible PiP standby showing “microphone off”.
4. In-place listening with keyboard status/partial text and stop control.
5. Matching result inserted into the original text field.
6. Language/privacy/personal dictionary and Pinyin reset controls.

For every file record device, iOS, locale, build and capture step. At 100% scale
check glyphs, clipping, overlap, status bars, third-party personal content and
every marketing claim. Use only device classes/sizes accepted by App Store
Connect at submission time.

## Account-owned fields

The owner must verify price/availability, age rating, category, export
compliance, App Privacy answers, contact/support information, review notes,
test account (not applicable unless the product changes), and release method.
These values are external metadata and are not proven by CI.

## Upload safety

- Keep `upload_metadata=false` until every screenshot is replaced and approved.
- Run Fastlane precheck against the final store version.
- Upload metadata does not submit the build for App Review.
- App Review submission is manual and requires explicit owner approval.
