# First run, keyboard authorization and recovery

## First-run checklist

1. Install the signed candidate selected for the test and open VoType once.
2. Tap **Add keyboard** and in iOS Settings choose:
   **General → Keyboard → Keyboards → Add New Keyboard → VoType/声入**.
3. Open the VoType keyboard entry and enable **Allow Full Access**. This is
   required only for local App Group session exchange; it does not give the
   developer a server or account.
4. Return to VoType and grant microphone and Speech Recognition after tapping
   the authorization control.
5. Optional hot path: tap **Enable in-place voice**. Confirm the visible PiP
   says standby and microphone off before returning to the target app.
6. In a normal text field switch keyboards with the globe key. Chinese Pinyin
   and English typing should work even before starting voice.

## Microphone states

| UI | Meaning | Expected action |
| --- | --- | --- |
| Solid microphone | Fresh user-started PiP standby | Tap to start in place; no App switch |
| Outline microphone | Containing app is not ready | Tap; follow the manual-open recovery message |
| Orange/starting | Request sent, audio not yet confirmed | Wait briefly; it must fall back or show recovery |
| Red/listening | Audio engine is active | Speak; tap again to stop |
| Processing | Audio ended, text is being finalized | Do not start another session until terminal result |

## Recovery playbook

| Symptom | Recovery |
| --- | --- |
| Voice tap does nothing visible | A hot acknowledgement waits at most 1.2 seconds; then use the visible Retry or manual-open action. The manual-open prompt appears immediately, within the three-second recovery bound; open VoType from the Home Screen. The recoverable request expires after 60 s |
| Keyboard missing | Re-add it in iOS Keyboard Settings and reopen the target app |
| Voice says Full Access unavailable | Enable Allow Full Access; verify both app targets use the same App Group profile |
| Microphone/Speech denied | iOS Settings → VoType → enable Microphone/Speech Recognition, then reopen VoType |
| Solid mic remains after closing PiP | Wait 3.5 s and reopen the keyboard; if still solid, stop using that build and capture diagnostics |
| Result appears after switching fields | Automatic insertion must be denied on a context mismatch. Explicit plain insertion goes to the current field only after you choose it; copy or discard does not require matching the original editor context |
| Listening is stuck after interruption | Tap stop, close PiP, foreground VoType and start a new session; record device/iOS/audio route if it repeats |
| Pinyin ranking is unwanted | VoType → Personal Dictionary → Reset Pinyin candidate learning |
| Local usage history is unwanted | VoType → Usage statistics → Reset |

Do not diagnose final-device failures from simulator behavior alone. Record the
candidate build number, device, iOS version, target app, permission state,
network state, audio route and exact recovery result.

If a held result appears after app switching, choose an explicit action. Plain
insert/preview requires the held token, no live selection, non-empty text and a
consumed payload identical to the preview; you may choose the current field. A
confirmed replace/delete also requires the original context, fingerprint and a
live selection. Copy compares the consumed payload with the frozen preview;
discard validates that the held token still peeks the frozen preview before
consuming that token's result. Neither depends on editor context. A cancellation
or handoff problem must show actual pending work or Retry; do not treat a status
indicator as proof that iOS retained the host process.

Signed physical-device microphone, Apple Speech, PiP lifecycle, extension eviction, and third-party insertion remain EXTERNAL / NOT_RUN for Slice A.
