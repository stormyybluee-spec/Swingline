//
//  SettingsView.swift
//  Swingline
//
//  Rebuilt as three expandable sections rather than one flat list: Profile,
//  Settings, Support. Profile starts open because the plan and the upgrade are
//  the only things most golfers come here for; the other two start closed so
//  the screen opens short and you choose what to read.
//
//  Every section is collapsible, Profile included. Nothing is pinned open,
//  because a section that cannot close is a section that is really just a
//  header, and the golfer can tell.
//
//  Carried over from the previous screen, deliberately, see BUILD-NOTES.md:
//    1. "Mirror the preview" is a three state value in the model (auto, on,
//       off) driven by a two state control, so auto is unreachable once
//       touched. Reproduced here.
//
//  Moved out of Settings in this pass:
//    - Club (for ball flight estimates), now chosen on the Record screen where
//      the golfer is actually holding the club.
//    - The whole Ball flight group (trace colour, line thickness, distance text
//      size, distance units).
//    - 3D joint markers, which lives with the 3D view controls.
//
//  Kept, because nothing asked for them to go, but folded into the new
//  structure rather than left loose: the notification switches now sit at the
//  foot of Settings, and the data controls, the Beta Founders gate and the
//  privacy card sit at the foot of Support. The data controls are one tap from
//  the surface and still say plainly what they do. An app that makes deleting
//  your own data hard is telling you something about how it thinks about your
//  data.
//
//  The new external actions (invite, sign in, rate, feedback, subscription)
//  raise a toast for now. Each one carries the real call beside it in a note,
//  so wiring them up later is a one line swap once AppInfo below holds real
//  values. Language is wired for real: it opens the iOS Settings app.
//

import SwiftUI
import UIKit

// MARK: - App level constants

/*
  Placeholders. Fill these in before shipping. The store ID drives both the
  share link and the review link, so a wrong one is wrong in two places.
*/
enum AppInfo {
    static let name = "Swingline"
    static let appStoreID = "0000000000"
    static let founderEmail = "founder@swingline.app"

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    static var storeURL: URL? { URL(string: "https://apps.apple.com/app/id\(appStoreID)") }
    static var reviewURL: URL? { URL(string: "https://apps.apple.com/app/id\(appStoreID)?action=write-review") }
    static var feedbackURL: URL? { URL(string: "mailto:\(founderEmail)?subject=Swingline%20feedback") }
    static var termsURL: URL? { URL(string: "https://swingline.app/terms") }
    static var privacyURL: URL? { URL(string: "https://swingline.app/privacy") }
}

// MARK: - Height options

/*
  Height is stored in centimetres whatever the units setting says, so switching
  units relabels the list and never rewrites the stored value. Imperial labels
  are derived, not a second source of truth.
*/
enum HeightOptions {
    static let centimetres = Array(140...210)

    static func list(imperial: Bool) -> [Option] {
        var out = [Option(value: "", label: "Not set")]
        out += centimetres.map { Option(value: String($0), label: label(cm: $0, imperial: imperial)) }
        return out
    }

    static func label(cm: Int, imperial: Bool) -> String {
        guard imperial else { return "\(cm) cm" }
        let inches = Int((Double(cm) / 2.54).rounded())
        return "\(inches / 12) ft \(inches % 12) in"
    }
}

// MARK: - Settings screen

struct SettingsView: View {
    @Environment(AppStore.self) private var store

    // Which sections are open. Profile only, on first paint.
    @State private var expandedSections: Set<String> = ["profile"]
    // Which app guide row is open. One at a time keeps the section short.
    @State private var expandedGuide: String? = nil

    @State private var showDeleteConfirm = false
    @State private var showAbout = false

    // Beta Founders gate. betaUnlocked persists across launches, so a tester
    // unlocks once and stays unlocked. The rest is transient sheet state.
    @AppStorage("betaUnlocked") private var betaUnlocked = false
    @State private var showBetaSheet = false
    @State private var betaPassword = ""
    @State private var betaError = false

    private var imperial: Bool { store.settings.units == "imperial" }

    var body: some View {
        ScreenContainer {
            Eyebrow(text: "Settings")
            GeometryReader { geo in
                Text("How you like it")
                    .font(.serif(TypeScale.display(geo.size.width)))
                    .foregroundStyle(Tok.bone)
            }
            .frame(height: 56)
            .padding(.top, 10)
            .padding(.bottom, 30)

            VStack(alignment: .leading, spacing: 14) {
                profileSection
                preferencesSection
                supportSection
            }
        }
        .alert("Delete all swings", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                store.swings.removeAll()
                store.notify("All swings deleted.", tone: .warn)
            }
        } message: {
            Text("Delete all \(store.swings.count) swings, their scores and their clips? This cannot be undone.")
        }
        .sheet(isPresented: $showAbout) {
            AboutSheet(onClose: { showAbout = false })
        }
        .sheet(isPresented: $showBetaSheet, onDismiss: {
            // If the sheet closes without a successful unlock, the toggle must
            // read as off, which it does because betaUnlocked was never set.
            betaPassword = ""
            betaError = false
        }) {
            BetaFoundersSheet(
                password: $betaPassword,
                showError: $betaError,
                onConfirm: {
                    // The whole gate. In this build the code is fixed at "999"
                    // and the unlock is simulated by setting the persisted flag.
                    if betaPassword == "999" {
                        betaUnlocked = true
                        showBetaSheet = false
                        store.notify("Beta Founders unlocked. Premium features are on.", tone: .good)
                    } else {
                        betaError = true
                    }
                },
                onCancel: {
                    showBetaSheet = false
                }
            )
        }
    }

    // MARK: 1. Profile

    private var profileSection: some View {
        SettingsSection(
            id: "profile",
            title: "Profile",
            subtitle: "Your plan, and who you are",
            expanded: $expandedSections
        ) {
            PlanCard(
                unlimited: store.quota.unlimited,
                remaining: store.quota.remaining,
                resetsOn: store.quota.resetsOn,
                onManage: {
                    store.quota.unlimited = false
                    store.quota.plan = "free"
                    store.notify("Back on the free tier. Your whole timeline is untouched.", tone: .good)
                },
                onUpgrade: { store.go(.paywall) }
            )
            .padding(.bottom, 4)

            NavRow(
                label: "Invite friends",
                note: "Send someone the app",
                systemImage: "square.and.arrow.up"
            ) {
                // Real version: ShareLink, or a UIActivityViewController, over
                // AppInfo.storeURL.
                store.notify("Share this app with your friends", tone: .info)
            }

            RowDivider()

            NavRow(
                label: "Sign in with Apple",
                note: "Carry your plan to another device",
                systemImage: "apple.logo"
            ) {
                // Real version: SignInWithAppleButton and an ASAuthorization
                // request for .fullName and .email.
                store.notify("Apple Sign-in coming soon", tone: .info)
            }
        }
    }

    // MARK: 2. Settings

    private var preferencesSection: some View {
        SettingsSection(
            id: "settings",
            title: "Settings",
            subtitle: "Language, units, camera and tracking",
            expanded: $expandedSections
        ) {
            // The system language picker, not an in-app one. iOS owns the
            // per-app language now, so duplicating it here only creates two
            // answers to the same question.
            NavRow(
                label: "Language",
                note: "Opens iOS Settings, where Swingline's language lives",
                trailing: currentLanguageLabel,
                systemImage: "globe"
            ) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }

            Text("Menus and labels follow the language you pick there. Coaching text stays in English until a native speaker has checked it, because a mistranslated drill teaches the wrong movement.")
                .font(.body(TypeScale.nano))
                .foregroundStyle(Tok.bone3)
                .fixedSize(horizontal: false, vertical: true)

            RowDivider()

            ChoiceRow(
                label: "Units",
                options: SettingsOptions.units,
                selection: store.settings.units
            ) { value in
                store.update { $0.units = value }
            }

            ChoiceRow(
                label: "Dominant hand",
                options: SettingsOptions.hands,
                selection: store.settings.dominantHand
            ) { value in
                store.update { $0.dominantHand = value }
            }

            // Height feeds the parts of the model that scale with the golfer
            // rather than with the frame. Stored in centimetres either way.
            DropdownRow(
                label: "Height",
                options: HeightOptions.list(imperial: imperial),
                selection: store.settings.height.map { String(Int($0.rounded())) } ?? ""
            ) { value in
                store.update { $0.height = Double(value) }
            }

            RowDivider()

            ChoiceRow(
                label: "Camera facing",
                options: SettingsOptions.cameraFacings,
                selection: store.settings.cameraFacing
            ) { value in
                store.update { $0.cameraFacing = value }
            }

            ChoiceRow(
                label: "Capture quality",
                options: SettingsOptions.cameraQualities,
                selection: store.settings.cameraQuality,
                joinNote: true
            ) { value in
                store.update { $0.cameraQuality = value }
            }

            ChoiceRow(
                label: "Tracking model",
                options: SettingsOptions.models,
                selection: store.settings.model,
                joinNote: true
            ) { value in
                store.update { $0.model = value }
            }

            ChoiceRow(
                label: "Skeleton style",
                options: SettingsOptions.overlayStyles,
                selection: store.settings.overlayStyle,
                joinNote: true
            ) { value in
                store.update { $0.overlayStyle = value }
            }

            SwitchRow(
                label: "Mirror the preview",
                note: "Off shows the camera as it really is, which is right when filming somebody else",
                isOn: store.settings.mirrorPreview == true
            ) { value in
                store.update { $0.mirrorPreview = value }
            }

            SwitchRow(
                label: "Listen for strike quality",
                note: "Uses the microphone during capture. Audio is analysed on device and never stored.",
                isOn: store.settings.micStrikeDetection
            ) { value in
                store.update { $0.micStrikeDetection = value }
            }

            DropdownRow(
                label: "Maximum recording length",
                options: SettingsOptions.recordLengths,
                selection: String(store.settings.maxRecordSeconds)
            ) { value in
                store.update { $0.maxRecordSeconds = Int(value) ?? 10 }
            }

            RowDivider()
            Eyebrow(text: "Reminders and sound")

            SwitchRow(
                label: "Streak reminders",
                note: "A nudge when a run is about to break",
                isOn: store.settings.notifyStreak
            ) { value in store.update { $0.notifyStreak = value } }

            SwitchRow(
                label: "Drill reminders",
                note: "Only for drills you have been given",
                isOn: store.settings.notifyDrill
            ) { value in store.update { $0.notifyDrill = value } }

            SwitchRow(
                label: "Sound effects",
                isOn: store.settings.soundEffects
            ) { value in store.update { $0.soundEffects = value } }

            SwitchRow(
                label: "Play the opening film",
                note: "Runs each time the app loads. Skippable at any point.",
                isOn: store.settings.playIntro
            ) { value in store.update { $0.playIntro = value } }

            SwitchRow(
                label: "Movement notes",
                note: "An occasional gentle note when swings show a heavy load pattern",
                isOn: store.settings.injuryNudges
            ) { value in store.update { $0.injuryNudges = value } }
        }
    }

    // MARK: 3. Support

    private var supportSection: some View {
        SettingsSection(
            id: "support",
            title: "Support",
            subtitle: "How it works, and how to reach us",
            expanded: $expandedSections
        ) {
            Eyebrow(text: "App guide and information")

            guideRow(
                id: "scores",
                title: "How scores work",
                body: "Every swing is scored in four areas: sequencing, rotation, balance and finish. Each area is only scored when the camera could actually see it, and anything it could not see is left out of the total rather than counted against you. That is why a score can move when you change camera angle, and why the range narrows as you record more swings."
            )
            guideRow(
                id: "metrics",
                title: "Understanding the metrics",
                body: "Each card shows one number for the moment you are paused on, with a coloured dot for how much to trust it. Green means the reading sits where it usually does, amber means it is unusual, red means it is well outside the normal band, and grey means it could not be measured for this swing. Cards that a camera angle cannot measure are hidden rather than guessed."
            )
            guideRow(
                id: "estimates",
                title: "Ball flight estimates",
                body: "Anything marked (Est.) is a model estimate, not a measurement. The app measures how fast your hands move at impact, then combines that with typical figures for the club you picked on the Record screen to estimate ball speed, carry, launch and spin. It does not watch the ball. Two golfers with the same hand speed and club will see the same estimate even if they struck it very differently, so treat these as a ballpark, not a launch monitor. The traced arc is an illustration of the flight shape, not the real path of your ball."
            )
            guideRow(
                id: "privacy",
                title: "Privacy promise",
                body: "Your swings are analysed on this device and stay on it. Video, tracking data and scores are never uploaded, and there is no account to sign into. If you delete a swing it is gone from the device, and exporting is the only way anything leaves it."
            )

            NavRow(label: "Show the setup guide again") {
                store.update { $0.onboarded = false }
                store.go(.onboarding)
            }

            RowDivider()
            Eyebrow(text: "Get in touch")

            NavRow(
                label: "Rate the app",
                note: "One tap, and it genuinely helps",
                systemImage: "star"
            ) {
                // Real version: SKStoreReviewController.requestReview(in:), or
                // UIApplication.shared.open(AppInfo.reviewURL) for the full page.
                store.notify("Rate this app on the App Store", tone: .info)
            }

            NavRow(
                label: "Feedback to founder",
                note: "Goes straight to a person, not a queue",
                systemImage: "envelope"
            ) {
                // Real version: UIApplication.shared.open(AppInfo.feedbackURL).
                store.notify("Send feedback to the founder", tone: .info)
            }

            NavRow(
                label: "Subscription",
                note: "Change or cancel your plan",
                systemImage: "creditcard"
            ) {
                // Real version: the manageSubscriptionsSheet, or store.go(.paywall)
                // for anyone not subscribed yet.
                store.notify("Manage your subscription", tone: .info)
            }

            NavRow(
                label: "About",
                note: "Version, terms and privacy policy",
                systemImage: "info.circle"
            ) {
                showAbout = true
            }

            SwitchRow(
                label: "Update notifications",
                note: "A note in the app when a new version is out",
                isOn: store.settings.updateNotifications
            ) { value in
                store.update { $0.updateNotifications = value }
            }

            RowDivider()
            Eyebrow(text: "Your data")

            ActionRow(
                label: "Export everything",
                note: "One file with every swing, score and tracking array",
                action: "Export"
            ) {
                store.notify("Export is not wired up in this build yet.", tone: .warn)
            }

            ActionRow(
                label: "Export with video",
                note: "Much larger, includes every clip",
                action: "Export"
            ) {
                store.notify("Export is not wired up in this build yet.", tone: .warn)
            }

            ActionRow(
                label: "Delete all swings",
                note: "\(store.swings.count) recorded. This cannot be undone.",
                action: "Delete",
                danger: true
            ) {
                showDeleteConfirm = true
            }

            RowDivider()
            Eyebrow(text: "Beta Founders")

            // A password gate for early testers to bypass the paywall. Toggling
            // on opens a secure entry sheet; the correct code sets the flag.
            // Toggling off relocks and does not prompt.
            SwitchRow(
                label: "Beta Founders access",
                note: betaUnlocked
                    ? "Unlocked. Every premium feature is available on this device."
                    : "For early testers. Enter the founders code to unlock premium features.",
                isOn: betaUnlocked
            ) { value in
                if value {
                    // Do not flip the flag yet. The sheet decides, so a toggle
                    // on with no code entered leaves it locked.
                    betaPassword = ""
                    betaError = false
                    showBetaSheet = true
                } else {
                    betaUnlocked = false
                    store.notify("Beta Founders locked. Premium features are off.", tone: .info)
                }
            }

            privacyCard
                .padding(.top, 6)
        }
    }

    // MARK: Pieces

    private var currentLanguageLabel: String {
        Language.all.first { $0.code == store.settings.language }?.native ?? "English"
    }

    /*
      Plain explanations of what the numbers mean, expandable in place so the
      section stays one scroll. Deliberately describes what a figure represents
      and how much to trust it, without describing how any of it is computed.
    */
    private func guideRow(id: String, title: String, body: String) -> some View {
        let open = expandedGuide == id
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    expandedGuide = open ? nil : id
                }
            } label: {
                HStack {
                    Text(title)
                        .font(.body(TypeScale.small))
                        .foregroundStyle(Tok.bone)
                    Spacer()
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Tok.bone3)
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                Text(body)
                    .font(.body(TypeScale.nano))
                    .foregroundStyle(Tok.bone3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
            }
        }
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: Tok.s3) {
            Eyebrow(text: "Your swings are yours")
            Text("Every swing you record is stored on this device and stays accessible whether or not you are paying for anything. Recording, storage and your whole history are free and unlimited, forever. Only new analysis runs are ever metered, and nothing you have already recorded is taken away.")
                .font(.body(TypeScale.small))
                .foregroundStyle(Tok.bone)
                .fixedSize(horizontal: false, vertical: true)
            Text("No account. No server. No upload. There is nowhere for your video to go, because this app does not have a backend to send it to.")
                .font(.body(TypeScale.micro))
                .foregroundStyle(Tok.bone3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(border: Tok.fairway)
    }
}

// MARK: - Expandable section

/*
  A section is a header you can press and a body that appears under it. The
  chevron rotates rather than swapping glyphs, so the control reads as one thing
  moving rather than two states flickering.
*/
private struct SettingsSection<Content: View>: View {
    private let id: String
    private let title: String
    private let subtitle: String
    private let content: Content
    @Binding private var expanded: Set<String>

    init(
        id: String,
        title: String,
        subtitle: String = "",
        expanded: Binding<Set<String>>,
        @ViewBuilder content: () -> Content
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self._expanded = expanded
        self.content = content()
    }

    private var isOpen: Bool { expanded.contains(id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isOpen { expanded.remove(id) } else { expanded.insert(id) }
                }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.serif(TypeScale.title))
                            .foregroundStyle(Tok.bone)
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.body(TypeScale.nano))
                                .foregroundStyle(Tok.bone3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tok.bone3)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint(isOpen ? "Collapses this section" : "Expands this section")

            if isOpen {
                VStack(alignment: .leading, spacing: 12) {
                    content
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                .fill(Tok.turf800.opacity(0.55))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                .strokeBorder(Tok.line, lineWidth: 1)
        }
    }
}

// MARK: - Rows

// A row that goes somewhere: another screen, a sheet, or out of the app. The
// chevron is the promise that something opens.
private struct NavRow: View {
    let label: String
    var note: String = ""
    var trailing: String? = nil
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Tok.bone2)
                        .frame(width: 20)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(.body(TypeScale.small))
                        .foregroundStyle(Tok.bone)
                    if !note.isEmpty {
                        Text(note)
                            .font(.body(TypeScale.nano))
                            .foregroundStyle(Tok.bone3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.body(TypeScale.nano))
                        .foregroundStyle(Tok.bone3)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tok.bone3)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// A hairline between clusters of rows inside one section.
private struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Tok.line)
            .frame(height: 1)
            .padding(.vertical, 2)
    }
}

// MARK: - About sheet

struct AboutSheet: View {
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.s5) {
            VStack(alignment: .leading, spacing: Tok.s2) {
                Eyebrow(text: "About", color: Tok.citrus)
                Text(AppInfo.name)
                    .font(.serif(TypeScale.title))
                    .foregroundStyle(Tok.bone)
                Text("Version \(AppInfo.version)  ·  Build \(AppInfo.build)")
                    .font(.data(TypeScale.micro))
                    .foregroundStyle(Tok.bone3)
            }

            Text("Swing analysis that runs entirely on this phone. No account, no server, no upload.")
                .font(.body(TypeScale.small))
                .foregroundStyle(Tok.bone2)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 0) {
                if let terms = AppInfo.termsURL {
                    Link(destination: terms) { linkRow("Terms of Use") }
                }
                Rectangle().fill(Tok.line).frame(height: 1)
                if let privacy = AppInfo.privacyURL {
                    Link(destination: privacy) { linkRow("Privacy Policy") }
                }
            }
            .background {
                RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                    .fill(Tok.turf800)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                    .strokeBorder(Tok.line, lineWidth: 1)
            }

            Button(action: onClose) {
                Text("Close")
                    .font(.body(TypeScale.small, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .foregroundStyle(Tok.ink)
                    .background(Capsule().fill(Tok.citrus))
            }
            .buttonStyle(PressScale())

            Spacer()
        }
        .padding(Tok.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AmbientGround())
        .presentationDetents([.medium])
    }

    private func linkRow(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.body(TypeScale.small))
                .foregroundStyle(Tok.bone)
            Spacer()
            Image(systemName: "arrow.up.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tok.bone3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

// MARK: - Plan card

// The plan, as a card that actually looks like the thing you would upgrade. An
// accent gradient and a lit border lift it off the plain rows, the plan name is
// large so the state reads at a glance, and the call to action is filled in the
// brand colour. On the paid tier it flips to a calmer outline.
struct PlanCard: View {
    let unlimited: Bool
    let remaining: Int
    let resetsOn: Date?
    let onManage: () -> Void
    let onUpgrade: () -> Void

    private var body_text: String {
        if unlimited {
            return "Unlimited analyses. Thanks for supporting the app."
        }
        let resets = resetsOn?.formatted(.dateTime.day().month()) ?? "next month"
        return "\(remaining) free \(remaining == 1 ? "analysis" : "analyses") left this month. Resets \(resets)."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "Current plan", color: Tok.citrus)
            Text(unlimited ? "Pro" : "Free")
                .font(.serif(34))
                .foregroundStyle(Tok.bone)
                .padding(.top, 6)
                .padding(.bottom, 6)
            Text(body_text)
                .font(.body(TypeScale.micro))
                .foregroundStyle(Tok.bone3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)

            Button(action: unlimited ? onManage : onUpgrade) {
                Text(unlimited ? "Manage subscription" : "Upgrade to Pro")
                    .font(.body(TypeScale.small, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .foregroundStyle(unlimited ? Tok.citrus : Tok.ink)
                    .background {
                        if unlimited {
                            Capsule().strokeBorder(Tok.citrus, lineWidth: 1)
                        } else {
                            Capsule().fill(Tok.citrus)
                        }
                    }
            }
            .buttonStyle(PressScale())
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(
                LinearGradient(
                    colors: unlimited
                        ? [Tok.citrus.opacity(0.18), Color(hex: "#1c2c18", opacity: 0.55)]
                        : [Tok.citrus.opacity(0.12), Color(hex: "#121a11", opacity: 0.65)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Tok.fairwayLit, lineWidth: 1)
        }
        .shadow(color: Tok.citrus.opacity(0.55), radius: 22, y: 10)
    }
}

// MARK: - Beta Founders password sheet

// A secure code entry for early testers to bypass the paywall. Deliberately
// small: a SecureField, a confirm, a cancel, and an inline error when the code
// is wrong. The parent owns the result, so this view only gathers input and
// reports the two buttons.
struct BetaFoundersSheet: View {
    @Binding var password: String
    @Binding var showError: Bool
    var onConfirm: () -> Void
    var onCancel: () -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.s5) {
            VStack(alignment: .leading, spacing: Tok.s2) {
                Eyebrow(text: "Beta Founders", color: Tok.citrus)
                Text("Enter code")
                    .font(.serif(TypeScale.title))
                    .foregroundStyle(Tok.bone)
                Text("Early testers only. This unlocks every premium feature on this device.")
                    .font(.body(TypeScale.small))
                    .foregroundStyle(Tok.bone3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Tok.s2) {
                SecureField("Founders code", text: $password)
                    .textContentType(.password)
                    .keyboardType(.numberPad)
                    .focused($fieldFocused)
                    .font(.data(TypeScale.body))
                    .foregroundStyle(Tok.bone)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous).fill(Tok.turf800))
                    .overlay {
                        RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                            .strokeBorder(showError ? Tok.rust : Tok.line, lineWidth: 1)
                    }
                    .onChange(of: password) { _, _ in
                        // Clear the error the moment the tester edits the field,
                        // so a stale wrong-code message does not linger.
                        if showError { showError = false }
                    }
                    .onSubmit(onConfirm)

                if showError {
                    Text("That code is not right. Try again.")
                        .font(.body(TypeScale.micro))
                        .foregroundStyle(Tok.rust)
                }
            }

            Button(action: onConfirm) {
                Text("Unlock")
                    .font(.body(TypeScale.small, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(Tok.ink)
                    .background(Capsule().fill(Tok.citrus))
            }
            .buttonStyle(PressScale())
            .disabled(password.isEmpty)
            .opacity(password.isEmpty ? 0.5 : 1)

            Button(action: onCancel) {
                Text("Cancel")
                    .font(.body(TypeScale.small))
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(Tok.bone2)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(Tok.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AmbientGround())
        .presentationDetents([.medium])
        .onAppear { fieldFocused = true }
    }
}
