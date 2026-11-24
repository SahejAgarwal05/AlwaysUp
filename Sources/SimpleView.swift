// SimpleView.swift — window container (Simple / Advanced switch) and the Simple view.

import AppKit
import SwiftUI

// MARK: - Container

struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
struct HeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    /// Reports this view's natural height so the window can fit itself to the content.
    func reportsContentHeight() -> some View {
        background(GeometryReader { g in Color.clear.preference(key: ContentHeightKey.self, value: g.size.height) })
    }
}

struct MainView: View {
    @ObservedObject var e: Engine
    @AppStorage("advancedUI") private var advanced = false
    @State private var contentHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    @State private var animateNextFit = false

    static func size(advanced: Bool) -> NSSize { advanced ? NSSize(width: 600, height: 820) : NSSize(width: 480, height: 640) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AlwaysUp").font(.title2.weight(.semibold))
                Spacer()
                Picker("", selection: $advanced) {
                    Text("Simple").tag(false)
                    Text("Advanced").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(GeometryReader { g in Color.clear.preference(key: HeaderHeightKey.self, value: g.size.height + 1) })
            Divider()
            if advanced { AdvancedView(e: e) } else { SimpleView(e: e) { advanced = true } }
        }
        .frame(minWidth: advanced ? 560 : 440, minHeight: 300)
        .onPreferenceChange(HeaderHeightKey.self) { headerHeight = $0; fitWindow() }
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0; fitWindow() }
        .onChange(of: advanced) { _ in animateNextFit = true; fitWindow(width: true) }
    }

    /// Size the window to its content (no empty space at the bottom), up to the screen height.
    private func fitWindow(width: Bool = false) {
        guard contentHeight > 0, headerHeight > 0,
              let w = NSApp.windows.first(where: { $0.title == "AlwaysUp" }) else { return }
        let targetWidth = width ? Self.size(advanced: advanced).width : w.contentLayoutRect.width
        var target = w.frameRect(forContentRect: NSRect(x: 0, y: 0, width: targetWidth, height: headerHeight + contentHeight))
        if let screen = w.screen ?? NSScreen.main { target.size.height = min(target.size.height, screen.visibleFrame.height) }
        var f = w.frame
        guard abs(f.height - target.height) > 1 || abs(f.width - target.width) > 1 else { return }
        f.origin.y += f.height - target.height    // keep the top edge in place
        f.size = target.size
        if let screen = w.screen, f.minY < screen.visibleFrame.minY { f.origin.y = screen.visibleFrame.minY }
        let animate = animateNextFit
        animateNextFit = false
        DispatchQueue.main.async { w.setFrame(f, display: true, animate: animate) }
    }
}

// MARK: - Simple

struct SimpleView: View {
    @ObservedObject var e: Engine
    let showAdvanced: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StatusCard(e: e)
                AwayCard(e: e)
                SetupCard(e: e)
                agentsCard
                if e.dockerAvailable { containersCard }
                saverCard
                footer
            }
            .padding(16)
            .reportsContentHeight()
        }
    }

    private var agentsCard: some View {
        Card("Your agents", subtitle: "Switch one on and your Mac stays awake while it runs — even with the lid closed.") {
            if e.detected.isEmpty && e.agentKinds.isEmpty {
                Text("No agents running right now. Start Claude Code, Codex, Gemini CLI, Aider… and they'll show up here.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                RowStack {
                    ForEach(e.agentKinds, id: \.self) { name in
                        AgentRuleRow(e: e, agent: name)
                        Divider()
                    }
                    ForEach(e.detected) { a in
                        AgentSwitchRow(e: e, a: a)
                        if a.id != e.detected.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private var containersCard: some View {
        Card("Docker containers", subtitle: "Switch one on to keep your Mac (and Docker) running while it's up.") {
            if e.containers.isEmpty {
                Text("Docker is running, but there are no containers right now.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                RowStack {
                    ForEach(e.containers) { c in
                        ContainerSwitchRow(e: e, c: c)
                        if c.id != e.containers.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private var saverCard: some View {
        Card("Save battery while the lid is closed", subtitle: saverSummary) {
            Toggle("", isOn: Binding(get: { e.trigger != .off }, set: { e.trigger = $0 ? .lidClosed : .off }))
                .toggleStyle(.switch).labelsHidden()
        } content: {
            EmptyView()
        }
    }

    private var saverSummary: String {
        var parts: [String] = []
        if e.saver.pauseApps { parts.append("pauses your other apps") }
        if e.saver.displayOff { parts.append("turns the screen off") }
        if e.saver.bluetoothOff { parts.append("turns Bluetooth off") }
        if e.saver.wifiOff { parts.append("turns Wi‑Fi off") }
        if e.saver.muteSpeakers && e.saver.muteHeadphones { parts.append("mutes the speakers and headphone jack") }
        else if e.saver.muteSpeakers { parts.append("mutes the speakers") }
        else if e.saver.muteHeadphones { parts.append("mutes the headphone jack") }
        if e.saver.lowPowerOnBattery && e.passwordless { parts.append("uses Low Power Mode on battery") }
        guard !parts.isEmpty else { return "Nothing selected — choose what to save in Advanced." }
        let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts[0]
        return list.prefix(1).uppercased() + list.dropFirst() + ". Opening the lid puts everything back the way you had it."
    }

    private var footer: some View {
        HStack {
            if let b = e.battery {
                Label("\(b.percent)% · \(b.onBattery ? "on battery" : "plugged in")",
                      systemImage: b.onBattery ? "battery.50" : "powerplug")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("More options…", action: showAdvanced).buttonStyle(.link)
        }
        .padding(.top, 2)
    }
}
