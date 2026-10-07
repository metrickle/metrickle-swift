## 0.2.0

- Survey follow-ups: a campaign can invite people who answered into a study (a booked video call or a self-guided test). `ActiveSurvey` has `followUp`, `qualifies()`, `invite()`, `followUpOffered()` and `followUpAccepted()`, and the built-in sheet shows the invite after the last answer when the response qualifies. Accepting records `$survey_follow_up` and opens the personal link in the browser.
- Opting out no longer leaves an anonymous id on the device: `optOut()` removes the stored anonymous id and session, an opted-out app never creates one at launch or on `reset()`, and `optIn()` creates a new one and fetches surveys and settings again.
- `feedback.isEnabled`: feedback can be switched off per platform in the dashboard. While it's off, `submit` sends nothing (this shipped in 0.1.0 but wasn't listed).

## 0.1.0

- Initial release: events, automatic UIKit screens and `.metrickleScreen` for SwiftUI, sessions, a persisted offline queue, VoiceOver and Dynamic Type context, rage taps, u-turns, form errors, surveys (headless and a built-in WCAG 2.2 AA sheet) and feedback with an optional screenshot.
