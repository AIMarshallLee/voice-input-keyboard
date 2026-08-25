# Automation inventory

## GitHub build and TestFlight workflow

| Field | Value |
| --- | --- |
| Trigger | Pull request, push to `main`, or manual `workflow_dispatch` |
| Owner | Repository maintainer |
| Automatic side effects | Tests, builds and GitHub artifact upload |
| Approval gate | App Store upload requires manual `publish=true`; metadata additionally requires `upload_metadata=true` |
| External APIs/tools | Homebrew/XcodeGen, Xcode, GitHub artifacts, Fastlane/App Store Connect |
| Output contract | Green/failed Actions run; non-publish runs upload an IPA plus unsigned `.xcarchive`; on publish, an App Store Connect build |
| Failure handling | Fail closed; no automatic retry; cleanup runs even after failure |
| Kill switch | Cancel run, disable workflow, revoke App Store API key/certificate |

Hard guardrails live in `.github/workflows/build.yml`: required simulator,
tests, generated Info.plist validation, isolated keychain, exact distribution
identity count, exact Team/Bundle/App Group checks, embedded profile UUID checks,
nested signature verification and manual publish inputs. The workflow contains
no App Review submission action.

GitHub Actions retains development IPA/archive and App Store IPA artifacts for
30 days.
Permanent evidence is the immutable run/build/artifact identifiers recorded in
the release evidence document, not a copied secret or local runner file.

## GitHub Pages workflow

Changes under `docs/` on `main` deploy the privacy and support pages. It has
read-only repository content permission plus Pages deployment permissions. It
does not read signing secrets or App Store credentials.

## On-device Foundation Models workflow

| Field | Value |
| --- | --- |
| Trigger | A user-started dictation with polish/format/translation enabled |
| Owner/approval | Device owner through settings and the current session |
| Inputs | Recognized text, selected text when editing, language and target language |
| Exact API surface | Apple `LanguageModelSession.respond(to:)`; no tools, web calls, filesystem access or outbound actions |
| Steering | Prompts in `TextProcessor.swift`, `SmartFormatter.swift`, `TranslationManager.swift` |
| Hard guardrails | OS/model availability, same-session settings, output length/sanity checks, nil/original-text fallback |
| Output contract | A bounded string returned to the app's deterministic processor |
| Side effects | The app may insert the validated string and update local aggregate counts; the model performs no side effect itself |
| Kill switch | Disable the relevant feature; unsupported devices skip the model |

There are no autonomous agents, tool-calling model loops, webhooks, scheduled
jobs or unattended user-data processing paths.
