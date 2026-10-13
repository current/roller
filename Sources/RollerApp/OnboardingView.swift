import AppKit
import SwiftUI
import RollerCore

/// The first-run guide: permission, the idea, and five shortcuts to start.
struct OnboardingView: View {
    @EnvironmentObject var store: ConfigStore
    let finish: () -> Void
    @State private var step = 0
    @State private var trusted = AX.isTrusted

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: permission
                case 2: essentials
                default: setup
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(28)
            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<4) { i in
                        Circle().fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                if step < 3 {
                    Button("Continue") { step += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Start Roller", action: finish)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 440)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in trusted = AX.isTrusted }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Windows on an endless strip").font(.largeTitle.bold())
            StripIllustration().frame(height: 90)
            Text("Roller puts every window side by side on a horizontal strip that runs past the edges of your screen. Opening a window never squeezes the others: the strip gets longer, and you scroll.")
            Text("Widths you set stay. Stack related windows into one column, and the layout is still there after a restart.")
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Allow Accessibility").font(.largeTitle.bold())
            Text("macOS only lets an app move and resize other apps' windows through Accessibility. It is the only permission Roller needs. Everything stays on your Mac; Roller doesn't read what's in your windows.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Image(systemName: trusted ? "checkmark.circle.fill" : "lock.circle")
                    .font(.title).foregroundStyle(trusted ? Color.green : Color.orange)
                Text(trusted ? "Roller has Accessibility access." : "Not allowed yet.")
            }
            if !trusted {
                HStack {
                    Button("Ask for Permission") { AX.requestTrust() }
                    Button("Open System Settings") { NSWorkspace.shared.open(URL(string: MacSetup.accessibilityPrivacyURL)!) }
                }
                Text("If the switch is already on but this still says “Not allowed”, remove Roller from the list with – and add it again. That happens after moving or rebuilding the app.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var essentials: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Five shortcuts to start").font(.largeTitle.bold())
            essential(.focusLeft, .focusRight, "Move along the strip")
            essential(.moveLeft, .moveRight, "Carry the focused window along")
            essential(.cycleWidth, nil, "Cycle the column through preset widths")
            essential(.stackIntoLeft, .popOutRight, "Stack into the left column, and pop back out")
            essential(.toggleFloat, nil, "Float a window off the strip, or put it back")
            Text("Or swipe left and right with \(store.config.swipeGestureFingers == .off ? "four" : "\(store.config.swipeGestureFingers.rawValue)") fingers. Every shortcut can be changed later.")
                .foregroundStyle(.secondary)
        }
    }

    private func essential(_ a: Action, _ b: Action?, _ text: String) -> some View {
        HStack {
            Text([a, b].compactMap { $0 }.compactMap { store.config.bindings[$0]?.first.map(KeyDisplay.string) }.joined(separator: " / "))
                .font(.system(.title3, design: .rounded).bold())
                .frame(width: 150, alignment: .leading)
            Text(text)
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Check your Mac's settings").font(.largeTitle.bold())
            Text("A few macOS settings decide whether everything works, above all the trackpad swipe. Mac Setup checks them and turns each one green as you fix it.")
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(MacSetup.run(fingers: store.config.swipeGestureFingers)) { c in
                        HStack(alignment: .top) {
                            Image(systemName: c.state == .ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(c.state == .ok ? Color.green : Color.orange)
                            Text(c.title)
                        }
                    }
                }
            }
            Button("Open Mac Setup") { AppDelegate.shared?.openSettings(page: .macSetup) }
        }
    }
}

/// A tiny picture of the strip: a few columns, the screen around two.
struct StripIllustration: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let cols: [CGFloat] = [0.18, 0.3, 0.22, 0.3, 0.2]
            ZStack(alignment: .topLeading) {
                ForEach(Array(cols.enumerated()), id: \.offset) { i, c in
                    let x = cols.prefix(i).reduce(0, +) * w * 0.82 - w * 0.08
                    RoundedRectangle(cornerRadius: 6)
                        .fill(i == 2 ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: c * w * 0.82 - 6, height: h - 16)
                        .offset(x: x, y: 8)
                }
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.7), lineWidth: 2)
                    .frame(width: w * 0.46, height: h)
                    .offset(x: w * 0.22)
            }
        }
        .clipped()
    }
}
