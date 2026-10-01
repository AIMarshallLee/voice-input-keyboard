# Privacy, data flow, retention and deletion

## Data flow

| Data | Source → destination | Purpose | Leaves device? |
| --- | --- | --- | --- |
| Live microphone audio | User → `AVAudioEngine` → Apple Speech | Speech recognition | May be processed by Apple when on-device recognition is unavailable; never sent to a VoType server |
| Session settings | Keyboard → App Group → app | Locale, feature flags, optional selected text | No |
| Partial/final text | App → App Group → matching keyboard session | Status and insertion | No, except text is derived from Apple Speech processing |
| Editor recovery context | Keyboard → App Group UserDefaults | Prevent insertion into the wrong field | No; only hashes are stored |
| Preferences/personal dictionary | User → App Group UserDefaults | Local behavior | No |
| Pinyin selection counts | Explicit candidate choice → App Group UserDefaults | Local ranking | No |
| Aggregate usage counts | Completed session → App Group UserDefaults | On-device activity display | No |
| Model input/output | App → Apple on-device Foundation Model → app | Optional polish/format/translation | No developer server or tool call |

VoType has no account identifier, advertising ID, analytics event stream,
tracking domain or developer-operated collection endpoint.

## Retention

| Record | Maximum/normal retention | Contents |
| --- | --- | --- |
| Pending settings | 60 seconds | Session, locale, feature flags, optional selected text |
| Live state | 2 minutes | Phase and partial text |
| Terminal result | 5 minutes or until matching consumption | Completed text or error |
| Readiness | 3.5 seconds without refresh | Standby/recording/processing only |
| Cancellation marker | Safely validated, unlinked markers become eligible for ordinary cleanup after 24 hours; invalid or unreadable proof is preserved and may persist beyond TTL, potentially indefinitely | Session/timestamp and, when needed, replacement UUID; no transcript or audio |
| Terminal receipt | Safely validated receipts become eligible for ordinary cleanup after 24 hours; linked handoff identity can remain until valid settlement | Session/timestamp; no transcript or audio |
| Recovery snapshot | 10 minutes | Session and context hashes; no editor plaintext |
| Preferences/personal dictionary | Until user changes/deletes or uninstalls | User-entered configuration |
| Pinyin learning | Until reset/uninstall; bounded to 2,000 spellings × 16 candidates | Candidate selection counts |
| Aggregate statistics | Until reset/uninstall; daily detail limited to seven days | Counts, locale distribution, streak dates |
| Raw audio file | Not retained | VoType does not create one |

Session files use atomic writes with complete file protection. Ordinary
read/cleanup removes only stale records that can be safely validated; invalid or
unreadable cancellation proof is preserved. Expiry is a safety bound, not a
promise that iOS runs a background cleanup exactly at that second.

The ordinary 24-hour value is an eligibility boundary, not an unconditional
deletion promise. Read-only inspection preserves unreadable cancellation evidence
instead of erasing it. A cancellation source may retain a random replacement UUID
and timestamp to prevent an unresolved handoff from being mistaken for safe
completion; it contains neither audio nor transcript. Result-only payloads do
not settle that link. Safely validated, eligible records may be removed during
ordinary access or later settings writes. Invalid or unreadable cancellation
proof may outlive the ordinary 24-hour TTL, potentially indefinitely; VoType has
no independent purge timer while the app is not running, and no user-visible
control deletes session-proof records separately.

## User deletion controls

- Delete personal dictionary entries individually in VoType.
- Reset all learned Pinyin rankings from the Personal Dictionary section.
- Reset aggregate usage counts from the Usage Statistics section.
- Revoke microphone, Speech or Full Access at any time to stop future access;
  revocation does not itself erase existing local preferences.
- Uninstall VoType to request iOS removal of its app and App Group data. Device
  backups and system-level restoration remain controlled by the user's Apple/iOS
  settings, not by the developer.

The public policy is `docs/privacy-policy.html`. App Store Privacy Details must
be answered from the final binary and this map; CI cannot submit those account
answers on behalf of the owner.

Signed physical-device microphone, Apple Speech, PiP lifecycle, extension eviction, and third-party insertion remain EXTERNAL / NOT_RUN for Slice A.
