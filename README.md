# Metrickle for iOS

Native Swift SDK for [Metrickle](https://metrickle.com): UX research and conversion analytics, accessibility first. It records screens, journeys and friction (rage taps, U-turns, form errors), segments everything by the assistive tech and accessibility settings people use, and runs in-app surveys in an accessible native sheet.

It follows the same [event model](https://metrickle.com/developers/events) as the web, React Native, Android and Flutter SDKs, so a funnel, task or survey means the same thing on every platform.

- iOS 15+ (builds on macOS 12+ for tests), Swift 6 language mode, no dependencies
- UIKit and SwiftUI
- Thread safe: every method can be called from any thread and never blocks the main thread on I/O

## Install

Swift Package Manager: in Xcode choose **File › Add Package Dependencies…** and enter

```
https://github.com/metrickle/metrickle-swift
```

or in `Package.swift`:

```swift
.package(url: "https://github.com/metrickle/metrickle-swift", from: "0.2.0"),
// ...
.target(name: "MyApp", dependencies: [.product(name: "Metrickle", package: "metrickle-swift")]),
```

## Quick start

### UIKit

```swift
import Metrickle

func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    Metrickle.configure(writeKey: "YOUR_WRITE_KEY")
    return true
}
```

Screens are tracked automatically from `viewDidAppear`. The name is the controller's `title`, or its class name without the `ViewController` suffix (`CheckoutViewController` → `Checkout`). Navigation, tab, page and split view controllers, system controllers and generic ones such as `UIHostingController<Content>` are skipped. To choose the name, or skip a controller:

```swift
final class CheckoutViewController: UIViewController, MetrickleScreenNaming {
    var metrickleScreenName: String? { "Checkout" } // nil to skip
}
```

Titles can contain user data (for example a person's name on a profile screen). Adopt `MetrickleScreenNaming` on those controllers.

### SwiftUI

```swift
import Metrickle
import SwiftUI

@main
struct MyApp: App {
    init() { Metrickle.configure(writeKey: "YOUR_WRITE_KEY") }

    var body: some Scene {
        WindowGroup { HomeView().metrickleScreen("Home") }
    }
}

struct CheckoutView: View {
    var body: some View {
        Form { /* ... */ }
            .metrickleScreen("Checkout", properties: ["step": 2])
    }
}
```

### Events

```swift
let mk = Metrickle.shared!

mk.track("plan_selected", properties: ["plan": "pro", "seats": 5, "annual": true])
mk.screen("Onboarding step 2")            // manual screen, e.g. for custom containers
mk.identify("user_123", traits: ["plan": "pro"])
mk.register(["experiment": "b"])            // added to every later event
mk.formError(form: "signup", field: "email", reason: "format") // field ids only, never what was typed
mk.reset()                                  // on logout: new anonymous id (none while opted out) and session
mk.flush()
```

Property values are strings (up to 1024 characters), numbers, booleans or `nil`, at most 64 per event. Names starting with `$` are reserved.

## Revenue from Stripe or RevenueCat

Connect your RevenueCat project (or Stripe account) in the Metrickle dashboard under Integrations → Revenue. Purchases, renewals, refunds and cancels then arrive server-side on the person you identified, so a refund takes back the task they completed. Log in to RevenueCat with the same id:

```swift
mk.identify(user.id)
_ = try await Purchases.shared.logIn(user.id)
// Or keep RevenueCat's id and name the Metrickle user:
// Purchases.shared.attribution.setAttributes(["metrickle_user_id": user.id])
```

## Options

```swift
Metrickle.configure(writeKey: "YOUR_WRITE_KEY", options: .init(
    host: "https://in.metrickle.com",
    flushInterval: 5,
    debug: true,
    beforeSend: { event in
        var event = event
        event.properties?["email"] = nil
        return event // or nil to drop it
    }
))
```

| Option | Default | |
|---|---|---|
| `host` | `https://in.metrickle.com` | Ingest origin (trailing slash is removed). |
| `cookieless` | `false` | Persist no ids. The server derives a daily-rotating visitor hash; surveys stay off. |
| `flushInterval` | `5` | Seconds between sends. Events are also sent at 20 queued and when the app goes to the background. |
| `sessionTimeout` | `1800` | Seconds of inactivity before a new session starts. |
| `automaticScreenTracking` | `true` | `$screen` from `UIViewController.viewDidAppear`. |
| `rageTaps` | `true` | `$rage_click` for 3 taps within 1 second inside 30pt. |
| `debug` | `false` | Log every queued event and each send result. |
| `beforeSend` | `nil` | Edit or drop (return `nil`) each event before it is queued. Runs on the SDK queue. |
| `appVersion` / `appBuild` | bundle values | Override `CFBundleShortVersionString` / `CFBundleVersion`. |

## What is collected automatically

| Event | When |
|---|---|
| `$screen` | A screen appears (UIKit automatically, SwiftUI with `.metrickleScreen`). `referrer` is the previous screen. |
| `$app_open` | Launch and each return to the foreground. |
| `$app_background` | The app goes to the background; the queue is then sent inside a background task. |
| `$u_turn` | Screen A → B → back to A within 7 seconds (`back_to`, `dwell_ms`). |
| `$rage_click` | 3 taps within 1 second in a 30pt radius (`selector`: accessibility identifier or class name, `text`: accessibility label or button title, up to 80 characters, never text field contents). |
| `$form_error` | You call `formError(form:field:reason:)`. Duplicates within 1.5 seconds are collapsed. |

Each batch carries device context (type, model identifier, iOS version, screen size in points, app version, locale, time zone) and accessibility flags, updated when a setting changes: `screen_reader` (VoiceOver), `keyboard` (hardware keyboard or Switch Control), `reduced_motion`, `reduced_transparency`, `high_contrast` (Increase Contrast), `inverted_colors`, `grayscale`, `bold_text`, `large_text` (text size above the default).

## Surveys

Campaigns are created in the Metrickle dashboard. The SDK fetches them at launch, on foreground (at most every 5 minutes) and on `refreshConfig()`, then decides on the device whether to show one: trigger (`load`, a screen name with an optional trailing `*`, or an event), delay, targeting, sampling, frequency caps and a 24-hour cooldown between any two surveys.

### Built-in sheet

On by default. The sheet is presented on the top-most view controller and is designed to meet WCAG 2.2 AA:

- Announced once when it opens, with VoiceOver focus on its "Survey" heading. It never appears over an alert or during a transition.
- Scale questions (NPS 0–10, CSAT and rating 1–5, CES 1–7) are single-select groups of buttons of at least 44×44pt. Each button's label includes the end label ("0, Not at all likely") and selected state, and the group is labelled with the question.
- Choice questions use toggles (multiple answers) or a list of selectable rows (single answer). Text questions have a visible label and a multiline field.
- Dynamic Type with no truncation (it scrolls, opens at full height for accessibility sizes, and stacks buttons), dark mode, Increase Contrast via semantic colours, and Reduce Motion (presented without animation).
- A visible Close button; swipe down, Escape and the VoiceOver escape gesture also dismiss it. It ends with your thank-you message or "Thanks for your feedback".
- When the campaign has a follow-up and the response qualifies, the submit button says "One moment…" (focus stays on it) while the sheet asks for the person's study link, for up to 5 seconds. With a link it shows the invite (below); otherwise the thank-you.
- Your brand accent (`branding.accent`) is used for fills only when it reaches 4.5:1 against the sheet background; otherwise the app's tint colour is used. Text on fills is white when it reaches 4.5:1, otherwise black (`textOn`, as on the web).

```swift
Metrickle.shared?.surveys.useBuiltInSheet = false // turn it off
Metrickle.shared?.surveys.show("cmp_123")        // QA: show an active campaign now, ignoring targeting
```

### Headless

Render surveys with your own UI. Your renderer replaces the built-in sheet and is called on the main thread:

```swift
let stop = Metrickle.shared?.surveys.onShow { survey in
    present(MySurveyView(campaign: survey.campaign,
        onAppear: { survey.shown() },
        onAnswer: { question, answer in survey.answer(question, answer) }, // Answer(score:), Answer(values:), Answer(text:)
        onFinish: { survey.complete() },
        onClose: { index in survey.dismiss(atIndex: index) }))
}
// later: stop?()
```

Answers become `$survey_shown`, `$survey_answered` and `$survey_dismissed` events, so responses join journeys and funnels.

### Follow-ups (study invites)

A campaign can invite the people who answered into a study: a booked video call (moderated) or a self-guided test on the web (unmoderated). The campaign then carries `survey.followUp` (`studyId`, `kind`, `prompt`, optional `when`, `incentive`, `durationMin`), only while the study is recruiting. `when` limits it to certain answers, for example NPS 0–6 or a particular choice.

The built-in sheet handles all of this. After the last answer it shows the invite: your prompt as a heading (VoiceOver focus moves to it), what taking part involves ("A 30-minute video call at a time that suits you." or "A short self-guided test of the site. Takes about 10–15 minutes."), any incentive ("As a thank-you: …"), and two buttons: "No thanks" and "Choose a time" (moderated) or "Take part" (unmoderated). The second opens the person's link in the browser and says so to VoiceOver. The invite never closes on its own.

With your own renderer:

```swift
Metrickle.shared?.surveys.onShow { survey in
    // ... ask the questions, calling survey.answer(_:_:) for each, then:
    survey.complete()
    guard survey.followUp != nil, survey.qualifies() else { return showThanks() }
    Task { @MainActor in
        guard let url = await survey.invite() else { return showThanks() } // nil: full, closed, or offline
        showInvite(survey.followUp!, onAccept: {
            survey.followUpAccepted()
            UIApplication.shared.open(url)
        })
        survey.followUpOffered() // once the invite is on screen
    }
}
```

- `qualifies()`: whether this response's answers meet `followUp.when` (always true without one; false with no follow-up).
- `invite()`: the person's personal study link. It asks the server once per response (later calls return the same answer) and returns nil when there's no follow-up, the response doesn't qualify, the user opted out, the study is full or no longer recruiting, the link isn't https, or the request fails. Only show an invite you have a link for.
- `followUpOffered()` / `followUpAccepted()`: each records `$survey_follow_up` once per response (`study`, `accepted: false` / `true`), so you can see how many people were asked and how many said yes.

## Feedback

```swift
let screenshot = Metrickle.shared?.feedback.captureScreenshot() // only after the user opts in
let result = await Metrickle.shared?.feedback.submit(
    category: .accessibility, // .bug, .confusing, .idea, .accessibility, .other
    message: "The pay button has no label",
    rating: 2,                // optional, 1–5
    screenshot: screenshot
)
if result?.ok == true { /* result.id */ }
```

Feedback can be switched off per platform under Settings → Research in the dashboard. While it's off, `Metrickle.shared?.feedback.isEnabled` is false and `submit` sends nothing, so use it to hide your feedback button.

The session, current screen, app version, device, screen size, locale and accessibility flags are attached. `captureScreenshot()` renders the key window as JPEG (quality 0.7, at most 1280px on the long edge, at most 2 MB). A screenshot can contain personal data, so only capture one when the user chooses to attach it. Text fields are not masked. A built-in feedback sheet is planned.

## Privacy

- No IDFA, IDFV or device serials. `anonymousId` is a random UUID stored in the app's `com.metrickle` UserDefaults suite and removed with the app. The model identifier (for example `iPhone15,2`) identifies a hardware model, not a device.
- Text field contents are never captured, only identifiers you pass.
- `optOut()` clears the queue, stops collection, removes the anonymous id and session from the device, and makes no further network calls (including config, feedback and study invites) until `optIn()`. The choice is persisted. While opted out no anonymous id is created, at launch or on `reset()`. Your own user id from `identify()` and the consent choice are kept.
- `optIn()` creates a new anonymous id and fetches surveys and settings again.
- Cookieless mode stores no ids at all.
- `consent(replay:)` records consent for session replay (not available on iOS yet; kept for parity with the web SDK).
- Unsent events (at most 1000) are kept on disk so they survive the app being killed; events older than 7 days are never sent.
- The package includes a `PrivacyInfo.xcprivacy`: no tracking, no tracking domains, collected data types Product Interaction and Other Usage Data (analytics, not linked to the user's identity, not used for tracking), and the UserDefaults required-reason API with reason `CA92.1`. If you call `identify()` with your own user ids, update your app's privacy manifest and App Store privacy answers to declare the data as linked to the user.

## Development

```sh
swift build && swift test
xcodebuild -scheme Metrickle -destination 'generic/platform=iOS Simulator' build
```
