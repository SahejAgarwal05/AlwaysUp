// Components.swift — shared building blocks used by both the Simple and Advanced views.

import AppKit
import SwiftUI

enum Durations {
    static let presets: [(String, TimeInterval)] = [
        ("15 minutes", 900), ("30 minutes", 1800), ("1 hour", 3600), ("2 hours", 7200), ("4 hours", 14400),
        ("8 hours", 28800), ("12 hours", 43200), ("24 hours", 86400), ("3 days", 259200),
    ]
}

// MARK: - Card

struct Card<Trailing: View, Content: View>: View {
    let title: String
    let subtitle: String?
    let trailing: Trailing
    let content: Content

    init(_ title: String, subtitle: String? = nil,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    if let s = subtitle {
                        Text(s).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                trailing
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.07)))
    }
}

// MARK: - Rows

/// Icon + title + optional explanation on the left, a switch on the right.
struct SwitchRow: View {
    let icon: String
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            RowLabel(icon: icon, title: title, detail: detail)
        }
        .toggleStyle(.switch)
    }
}

/// Icon + title + optional explanation on the left, any control on the right.
struct ControlRow<Control: View>: View {
    let icon: String
    let title: String
    var detail: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center) {
            RowLabel(icon: icon, title: title, detail: detail)
            Spacer(minLength: 12)
            control()
        }
    }
}

struct RowLabel: View {
    let icon: String
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let d = detail {
                    Text(d).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Rows separated by thin dividers.
struct RowStack<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content() }
    }
}

// MARK: - Durations

/// Hours + minutes fields with a stepper.
struct HMField: View {
    let value: TimeInterval
    let set: (TimeInterval) -> Void

    var body: some View {
        let h = Int(value) / 3600, m = (Int(value) % 3600) / 60
        HStack(spacing: 4) {
            TextField("", value: Binding(get: { h }, set: { apply(h: $0, m: m) }), format: .number)
                .frame(width: 40).multilineTextAlignment(.trailing)
            Text("h").foregroundStyle(.secondary)
            TextField("", value: Binding(get: { m }, set: { apply(h: h, m: $0) }), format: .number)
                .frame(width: 34).multilineTextAlignment(.trailing)
            Text("m").foregroundStyle(.secondary)
            Stepper("", onIncrement: { set(value + 900) }, onDecrement: { set(max(900, value - 900)) })
                .labelsHidden()
        }
    }

    private func apply(h: Int, m: Int) {
        set(TimeInterval(max(60, max(0, h) * 3600 + min(59, max(0, m)) * 60)))
    }
}

/// A dropdown of common durations, "Unlimited" and "Custom…" (which shows hour/minute fields).
struct DurationPicker: View {
    @Binding var value: TimeInterval?
    var unlimitedLabel = "Unlimited"
    @State private var custom = false

    private var isCustom: Bool {
        guard let v = value else { return false }
        return !Durations.presets.contains { $0.1 == v }
    }

    private var label: String {
        guard let v = value else { return unlimitedLabel }
        return Durations.presets.first { $0.1 == v }?.0 ?? formatDuration(v)
    }

    var body: some View {
        HStack(spacing: 8) {
            if (custom || isCustom), let v = value { HMField(value: v) { value = $0 } }
            Menu(label) {
                Button(unlimitedLabel) { custom = false; value = nil }
                Divider()
                ForEach(Durations.presets, id: \.1) { p in Button(p.0) { custom = false; value = p.1 } }
                Divider()
                Button("Custom…") { custom = true; if value == nil { value = 5400 } }
            }
            .fixedSize()
        }
    }
}

// MARK: - Status card (main on/off control, used by both views)

struct StatusCard: View {
    @ObservedObject var e: Engine
    @State private var custom = false

    static let quick: [(String, TimeInterval)] = [
        ("For 30 minutes", 1800), ("For 1 hour", 3600), ("For 2 hours", 7200), ("For 4 hours", 14400), ("For 8 hours", 28800),
    ]
    static let batteryStops = [80, 60, 50, 40, 30, 20, 10]

    private var logoState: LogoState {
        if !e.awake { return .off }
        return e.saverActive ? .saver : .awake
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: Logo.menuBar(logoState))
                .renderingMode(.template)
                .resizable()
                .frame(width: 56, height: 56)
                .foregroundStyle(e.awake ? Color.primary : Color.secondary)

            VStack(spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }

            if e.manualActive {
                Button { e.stopManual() } label: { Text("Turn Off").frame(maxWidth: 220) }
                    .controlSize(.large)
            } else {
                Button { e.startManual() } label: { Text("Keep Awake").frame(maxWidth: 220) }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }

            HStack(spacing: 8) {
                Menu(stopLabel) {
                    Button("Until I turn it off") { setTime(nil) }
                    Divider()
                    ForEach(Self.quick, id: \.1) { c in Button(c.0) { setTime(c.1) } }
                    Button("Custom time…") { custom = true; setTime(e.manualDuration ?? 5400) }
                    Divider()
                    Menu("Until battery is…") {
                        ForEach(Self.batteryStops, id: \.self) { p in Button("\(p)%") { setBattery(p) } }
                    }
                }
                .fixedSize()
                if (custom || isCustomTime), let d = e.manualDuration {
                    HMField(value: d) { setTime($0) }
                }
            }

            Toggle("Only while plugged in", isOn: $e.onlyWhileCharging)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Your Mac stays awake only while charging. Unplug it and it can sleep; plug it back in and AlwaysUp resumes.")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.08)))
    }

    private var title: String {
        if e.waitingForCharger { return "Waiting for the charger" }
        return e.awake ? "Awake — you can close the lid" : "Your Mac sleeps normally"
    }

    private var subtitle: String {
        e.simulating.isEmpty ? realSubtitle : "\(realSubtitle)\nSimulating: \(e.simulating)"
    }

    private var realSubtitle: String {
        if e.waitingForCharger { return "Plug in and it'll stay awake again." }
        if e.batteryTripped || e.thermalTripped || e.authBlocked { return e.reasonText }
        if e.manualActive {
            if let p = e.manualUntilBattery {
                let now = e.battery.map { " · now \($0.percent)%" } ?? ""
                return "Until the battery drops to \(p)%\(now)"
            }
            if let u = e.manualUntil { return "\(formatDuration(u.timeIntervalSince(e.now))) left" }
            return "Stays on until you turn it off"
        }
        if e.awake, e.holdingCount > 0 {
            return "Staying awake while \(e.holdingCount) agent\(e.holdingCount == 1 ? " is" : "s are") running"
        }
        return "Turn it on, or switch on an agent below"
    }

    private var isCustomTime: Bool {
        guard e.manualUntilBattery == nil, let d = e.manualDuration else { return false }
        return !Self.quick.contains { $0.1 == d }
    }

    private var stopLabel: String {
        if let p = e.manualUntilBattery { return "Until battery is \(p)%" }
        guard let d = e.manualDuration else { return "Until I turn it off" }
        return Self.quick.first { $0.1 == d }?.0 ?? "For \(formatDuration(d))"
    }

    /// Changing the rule while it's on restarts with the new rule.
    private func setTime(_ d: TimeInterval?) {
        if d == nil || Self.quick.contains(where: { $0.1 == d }) { custom = false }
        e.manualUntilBattery = nil
        e.manualDuration = d
        if e.manualActive { e.startManual() }
    }

    private func setBattery(_ p: Int) {
        custom = false
        if e.manualActive { e.startManual(untilBattery: p) } else { e.manualUntilBattery = p; e.manualDuration = nil }
    }
}

// MARK: - Setup + warnings

struct SetupCard: View {
    @ObservedObject var e: Engine
    var body: some View {
        if e.authBlocked {
            HStack {
                Label("Password prompt was cancelled.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Try Again") { e.retryAuth() }
            }
        }
        if !e.passwordless {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "key.fill").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("One-time setup").font(.headline)
                    Text("Let AlwaysUp switch on and off by itself without asking for your password — needed so it can react while the lid is closed.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Set Up…") { e.togglePasswordless() }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.3)))
        }
    }
}

// MARK: - "While you were away" note

struct AwayCard: View {
    @ObservedObject var e: Engine
    var body: some View {
        if let a = e.lastAway {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "moon.stars").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("While you were away").font(.headline)
                    Text(a.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button { e.dismissAway() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.3)))
        }
    }
}

// MARK: - Agent switch row

struct AgentSwitchRow: View {
    @ObservedObject var e: Engine
    let a: DetectedAgent

    var body: some View {
        Toggle(isOn: Binding(get: { e.isMarked(a) }, set: { $0 ? e.addAgent(a, byName: false) : e.unmark(a) })) {
            RowLabel(icon: a.isApp ? "macwindow" : "terminal", title: a.agent,
                     detail: "PID \(String(a.proc.pid)) · running \(formatDuration(e.now.timeIntervalSince(a.proc.start)))")
        }
        .toggleStyle(.switch)
    }
}

// MARK: - Docker container switch row

struct ContainerSwitchRow: View {
    @ObservedObject var e: Engine
    let c: Container

    var body: some View {
        Toggle(isOn: Binding(get: { e.isMarked(c) }, set: { $0 ? e.addContainer(c) : e.unmark(c) })) {
            RowLabel(icon: "shippingbox", title: c.name,
                     detail: "\(c.image) · \(c.isRunning ? c.status : "paused")")
        }
        .toggleStyle(.switch)
    }
}

/// Small rounded label.
struct Chip: View {
    let text: String
    var icon: String?
    var body: some View {
        HStack(spacing: 4) {
            if let i = icon { Image(systemName: i) }
            Text(text).monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}
