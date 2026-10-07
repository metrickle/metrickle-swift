import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum BuiltInSurveySheet {
    /// The built-in renderer, or nil where there is no UIKit.
    static func renderer(for client: Metrickle) -> SurveyRenderer? {
        #if canImport(UIKit)
        return { [weak client] survey in
            SurveySheetPresenter.present(survey, accentHex: client?.accent.get())
        }
        #else
        return nil
        #endif
    }
}

/// Opens a study link in the system browser.
@MainActor
func openInBrowser(_ url: URL) {
    #if canImport(UIKit) && !os(watchOS)
    UIApplication.shared.open(url)
    #elseif canImport(AppKit)
    NSWorkspace.shared.open(url)
    #endif
}

/// What the invite says taking part involves (same copy as the web card).
func followUpDescription(_ f: FollowUpConfig) -> String {
    switch f.kind {
    case .moderated: "A \(f.durationMin.map { "\($0)-minute " } ?? "")video call at a time that suits you."
    case .unmoderated: "A short self-guided test of the site. Takes about 10–15 minutes."
    }
}

/// Default scale end labels per question type (same as the web UI).
let scaleEnds: [QuestionType: (String, String)] = [
    .nps: ("Not at all likely", "Extremely likely"),
    .csat: ("Very dissatisfied", "Very satisfied"),
    .ces: ("Very difficult", "Very easy"),
    .rating: ("Poor", "Excellent"),
]

#if canImport(UIKit)
import SwiftUI
import UIKit

final class SurveyHostingController: UIHostingController<SurveySheetView> {}

@MainActor
enum SurveySheetPresenter {
    private static weak var current: UIViewController?

    static func present(_ survey: ActiveSurvey, accentHex: String?) {
        // Never stack on another survey, an alert, or a transition in progress; release the engine instead.
        guard current == nil, let top = topViewController() else { return survey.complete() }
        let animated = !UIAccessibility.isReduceMotionEnabled
        let model = SurveySheetModel(survey: survey)
        let palette = SurveyPalette(accentHex: accentHex, tint: top.view.window?.tintColor ?? .systemBlue)
        let host = SurveyHostingController(rootView: SurveySheetView(model: model, palette: palette))
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            if UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory { sheet.selectedDetentIdentifier = .large }
        }
        host.presentationController?.delegate = model
        model.close = { [weak host] in host?.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) }
        current = host
        top.present(host, animated: animated) {
            survey.shown()
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }

    static func topViewController() -> UIViewController? {
        var top = PlatformHooks.keyWindow()?.rootViewController
        while let next = top?.presentedViewController { top = next }
        guard let top, !(top is UIAlertController), !top.isBeingDismissed, !top.isBeingPresented else { return nil }
        return top
    }
}

/// Brand accent for fills, used only when it reaches 4.5:1 against the sheet background; otherwise the app tint.
/// Text on a fill is black or white, whichever `textOn` picks.
struct SurveyPalette {
    let accent: Color
    let onAccent: Color
    let error = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#f07070") : UIColor(hex: "#b3261e") })

    init(accentHex: String?, tint: UIColor) {
        let fill = UIColor { traits in
            let bg = UIColor.systemBackground.resolvedColor(with: traits).hex
            if let a = accentHex, rgb(a) != nil, contrastRatio(a, bg) >= 4.5 { return UIColor(hex: a) }
            return tint.resolvedColor(with: traits)
        }
        accent = Color(fill)
        onAccent = Color(UIColor { textOn(fill.resolvedColor(with: $0).hex) == "#ffffff" ? .white : .black })
    }
}

extension UIColor {
    convenience init(hex: String) {
        let (r, g, b) = rgb(hex) ?? (0, 0, 0)
        self.init(red: r, green: g, blue: b, alpha: 1)
    }

    var hex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return hexString(r: Double(r), g: Double(g), b: Double(b))
    }
}

@MainActor
final class SurveySheetModel: NSObject, ObservableObject, UIAdaptivePresentationControllerDelegate {
    let survey: ActiveSurvey
    var close: () -> Void = {}
    enum Screen: Equatable { case question, invite(URL), thanks }

    @Published var index = 0
    @Published var screen = Screen.question
    /// Waiting for the study link after the last answer; the submit button says "One moment…".
    @Published var waiting = false
    @Published var score: Int?
    @Published var selected: [String] = []
    @Published var text = ""
    @Published var error: String?
    private var finished = false
    /// `survey.complete()` was called: closing now records no dismissal.
    private var completed = false

    init(survey: ActiveSurvey) { self.survey = survey }

    var questions: [Question] { survey.campaign.questions }
    var question: Question { questions[index] }
    var isLast: Bool { index == questions.count - 1 }

    func submit() {
        guard !waiting else { return }
        let q = question
        let answer: Answer?
        switch q.type {
        case .text: answer = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : Answer(text: text)
        case .choice: answer = selected.isEmpty ? nil : Answer(values: (q.choices ?? []).filter(selected.contains))
        default: answer = score.map { Answer(score: $0) }
        }
        if answer == nil && q.required {
            let message = q.type == .text ? "Please write an answer, or close the survey." : "Please choose an answer, or close the survey."
            error = message
            UIAccessibility.post(notification: .announcement, argument: message)
            return
        }
        if let answer { survey.answer(q, answer) }
        advance()
    }

    func skip() {
        guard !waiting else { return }
        advance()
    }

    private func advance() {
        error = nil
        if isLast {
            completed = true
            survey.complete()
            guard survey.followUp != nil, survey.qualifies() else { screen = .thanks; return }
            // Ask for the personal link before saying anything: no invite is shown that can't be kept.
            // Focus stays on the submit button meanwhile.
            waiting = true
            UIAccessibility.post(notification: .announcement, argument: "One moment…")
            Task { @MainActor in
                let url = await survey.invite(timeout: 5)
                waiting = false
                guard !finished else { return }
                if let url {
                    screen = .invite(url)
                    survey.followUpOffered()
                } else {
                    screen = .thanks
                }
            }
        } else {
            index += 1
            score = nil
            selected = []
            text = ""
        }
    }

    func toggle(_ choice: String, multiple: Bool) {
        if let i = selected.firstIndex(of: choice) { selected.remove(at: i) }
        else if multiple { selected.append(choice) }
        else { selected = [choice] }
        error = nil
    }

    func declineInvite() { screen = .thanks }

    func acceptInvite(_ url: URL) {
        survey.followUpAccepted()
        openInBrowser(url)
        screen = .thanks
    }

    func dismissTapped() {
        finish()
        close()
    }

    /// Swipe down, Escape or the VoiceOver escape gesture.
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finish() }

    private func finish() {
        guard !finished else { return }
        finished = true
        if !completed { survey.dismiss(atIndex: index) }
    }
}

struct SurveySheetView: View {
    enum Focus: Hashable { case heading, prompt, invite, thanks }

    @ObservedObject var model: SurveySheetModel
    let palette: SurveyPalette
    @AccessibilityFocusState private var focus: Focus?
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var cell: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var textHeight: CGFloat = 120

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch model.screen {
                    case .question: question(model.question)
                    case .invite(let url): invite(url)
                    case .thanks: thanks
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundColor(.primary)
        .background(Color(UIColor.systemBackground).ignoresSafeArea())
        .accessibilityAction(.escape) { model.dismissTapped() }
        .onAppear { moveFocus(.heading, after: 0.6) }
        .onChange(of: model.index) { _ in moveFocus(.prompt) }
        .onChange(of: model.screen) { screen in
            switch screen {
            case .question: break
            case .invite: moveFocus(.invite)
            case .thanks: moveFocus(.thanks)
            }
        }
    }

    private func moveFocus(_ target: Focus, after seconds: Double = 0.2) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            focus = target
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Survey")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($focus, equals: .heading)
                if model.questions.count > 1 && model.screen == .question {
                    Text("Question \(model.index + 1) of \(model.questions.count)").font(.subheadline)
                }
            }
            Spacer(minLength: 0)
            Button(action: model.dismissTapped) {
                Text("Close")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 12)
                    .frame(minWidth: 44, minHeight: 44)
                    .overlay(Capsule().strokeBorder(Color(UIColor.secondaryLabel)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close survey")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func question(_ q: Question) -> some View {
        switch q.type {
        case .text: textQuestion(q)
        case .choice: choiceQuestion(q)
        default: scaleQuestion(q)
        }
        if let error = model.error {
            Label { Text(error) } icon: { Image(systemName: "exclamationmark.circle") }
                .foregroundColor(palette.error)
                .fixedSize(horizontal: false, vertical: true)
        }
        actions(q)
    }

    private func prompt(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityFocused($focus, equals: .prompt)
    }

    private func scaleQuestion(_ q: Question) -> some View {
        let range = q.type.scale ?? 1...5
        let ends = scaleEnds[q.type] ?? ("", "")
        let low = q.lowLabel.flatMap { $0.isEmpty ? nil : $0 } ?? ends.0
        let high = q.highLabel.flatMap { $0.isEmpty ? nil : $0 } ?? ends.1
        return VStack(alignment: .leading, spacing: 12) {
            prompt(q.prompt)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: cell), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(Array(range), id: \.self) { n in
                    scaleButton(n, q: q, range: range, low: low, high: high)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(q.prompt)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(range.lowerBound) = \(low)")
                Text("\(range.upperBound) = \(high)")
            }
            .font(.footnote)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true) // each button's label already includes its end label
        }
    }

    private func scaleButton(_ n: Int, q: Question, range: ClosedRange<Int>, low: String, high: String) -> some View {
        let selected = model.score == n
        var label = q.type == .rating ? (n == 1 ? "1 star" : "\(n) stars") : "\(n)"
        if n == range.lowerBound { label += ", \(low)" } else if n == range.upperBound { label += ", \(high)" }
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button {
            model.score = selected ? nil : n
            model.error = nil
        } label: {
            Text("\(n)")
                .font(.body.weight(selected ? .bold : .regular))
                .foregroundColor(selected ? palette.onAccent : .primary)
                .frame(maxWidth: .infinity, minHeight: cell)
                .background(shape.fill(selected ? palette.accent : Color(UIColor.secondarySystemBackground)))
                .overlay(shape.strokeBorder(selected ? Color.primary : Color(UIColor.secondaryLabel), lineWidth: selected ? 2 : 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func choiceQuestion(_ q: Question) -> some View {
        let multiple = q.multiple == true
        return VStack(alignment: .leading, spacing: 8) {
            prompt(q.prompt + (multiple ? " (choose all that apply)" : ""))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(q.choices ?? [], id: \.self) { choice in
                    let on = model.selected.contains(choice)
                    if multiple {
                        Toggle(isOn: Binding(get: { on }, set: { _ in model.toggle(choice, multiple: true) })) {
                            Text(choice).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(minHeight: 44)
                    } else {
                        Button { model.toggle(choice, multiple: false) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                                    .font(.title3)
                                    .foregroundColor(on ? palette.accent : Color(UIColor.secondaryLabel))
                                    .accessibilityHidden(true)
                                Text(choice).fontWeight(on ? .semibold : .regular).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(choice)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(q.prompt)
        }
    }

    private func textQuestion(_ q: Question) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            prompt(q.prompt)
            if let hint = q.placeholder, !hint.isEmpty {
                Text(hint).font(.footnote).fixedSize(horizontal: false, vertical: true).accessibilityHidden(true)
            }
            TextEditor(text: $model.text)
                .frame(minHeight: textHeight)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(UIColor.secondaryLabel)))
                .accessibilityLabel(q.prompt)
                .accessibilityHint(q.placeholder ?? "")
                .onChange(of: model.text) { value in
                    if value.utf16.count > maxSurveyText { model.text = truncate(value, maxSurveyText) }
                }
        }
    }

    @ViewBuilder
    private func actions(_ q: Question) -> some View {
        let primary = Button(action: model.submit) {
            Text(model.waiting ? "One moment…" : model.isLast ? "Submit" : "Next")
                .font(.body.weight(.semibold))
                .foregroundColor(palette.onAccent)
                .padding(.horizontal, 20)
                .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil, minHeight: 44)
                .background(Capsule().fill(palette.accent))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        let skip = Button(action: model.skip) {
            Text("Skip")
                .font(.body.weight(.semibold))
                .padding(.horizontal, 20)
                .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil, minHeight: 44)
                .overlay(Capsule().strokeBorder(Color(UIColor.secondaryLabel)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        if typeSize.isAccessibilitySize {
            VStack(spacing: 12) {
                primary
                if !q.required { skip }
            }
        } else {
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                if !q.required { skip }
                primary
            }
        }
    }

    /// The study invite: the prompt as a focused heading, what taking part involves, any incentive, and a choice.
    /// It never closes on its own.
    private func invite(_ url: URL) -> some View {
        let fu = model.survey.followUp
        let action = fu?.kind == .moderated ? "Choose a time" : "Take part"
        let accept = Button { model.acceptInvite(url) } label: {
            Text(action)
                .font(.body.weight(.semibold))
                .foregroundColor(palette.onAccent)
                .padding(.horizontal, 20)
                .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil, minHeight: 44)
                .background(Capsule().fill(palette.accent))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(action), opens in your browser")
        let decline = Button(action: model.declineInvite) {
            Text("No thanks")
                .font(.body.weight(.semibold))
                .padding(.horizontal, 20)
                .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil, minHeight: 44)
                .overlay(Capsule().strokeBorder(Color(UIColor.secondaryLabel)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(fu?.prompt ?? "")
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($focus, equals: .invite)
                if let fu {
                    Text(followUpDescription(fu)).fixedSize(horizontal: false, vertical: true)
                    if let incentive = fu.incentive, !incentive.isEmpty {
                        Text("As a thank-you: \(incentive)").fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if typeSize.isAccessibilitySize {
                VStack(spacing: 12) {
                    accept
                    decline
                }
            } else {
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    decline
                    accept
                }
            }
        }
    }

    private var thanks: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.survey.campaign.thankYou.flatMap { $0.isEmpty ? nil : $0 } ?? "Thanks for your feedback")
                .font(.title3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityFocused($focus, equals: .thanks)
            Button(action: model.dismissTapped) {
                Text("Done")
                    .font(.body.weight(.semibold))
                    .foregroundColor(palette.onAccent)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(palette.accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}
#endif
