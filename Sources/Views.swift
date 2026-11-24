// Views.swift — the Advanced view: same look as Simple, with every option.

import SwiftUI

struct AdvancedView: View {
    @ObservedObject var e: Engine
    @State private var showPicker = false
    @State private var addMode: AddMode?
    @State private var agentsText = ""

    enum AddMode: String, Identifiable { case pid, name; var id: String { rawValue } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StatusCard(e: e)
                AwayCard(e: e)
                SetupCard(e: e)
                keptCard
                saverCard
                batteryCard
                generalCard
            }
            .padding(16)
            .reportsContentHeight()
        }
        .sheet(isPresented: $showPicker) { ProcessPicker(e: e) { showPicker = false } }
        .sheet(item: $addMode) { mode in AddSheet(e: e, mode: mode) { addMode = nil } }
    }

    // MARK: Kept running

    private var unmarked: [DetectedAgent] { e.detected.filter { !e.isMarked($0) } }
    /// Kinds of agent running now that don't have an "always keep every …" rule yet.
    private var openKinds: [String] { e.agentKinds.filter { !e.keepsEvery($0) } }
    private var unmarkedContainers: [Container] { e.containers.filter { !e.isMarked($0) } }

    private var keptCard: some View {
        Card("Kept running",
             subtitle: "Your Mac stays awake while these run, and Saver Mode never pauses them. Each one can have its own time limit.") {
            addMenu
        } content: {
            RowStack {
                if e.targets.isEmpty {
                    Text("Nothing yet — switch on an agent below, or use Add.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(e.targets) { t in
                    TargetRow(e: e, t: t)
                    if t.id != e.targets.last?.id { Divider() }
                }

                if !unmarked.isEmpty || !unmarkedContainers.isEmpty || !openKinds.isEmpty {
                    Text("Found on this Mac").font(.subheadline.weight(.semibold)).padding(.top, 6)
                    ForEach(openKinds, id: \.self) { name in
                        AgentRuleRow(e: e, agent: name)
                    }
                    ForEach(unmarked) { a in
                        AgentSwitchRow(e: e, a: a)
                    }
                    ForEach(unmarkedContainers) { c in
                        ContainerSwitchRow(e: e, c: c)
                    }
                }

                Divider().padding(.vertical, 2)
                HStack(spacing: 8) {
                    Text("New items run for").foregroundStyle(.secondary)
                    DurationPicker(value: $e.defaultLimit)
                    Text("then").foregroundStyle(.secondary)
                    Menu(shortAction(e.defaultAction)) {
                        ForEach(ExpireAction.allCases) { a in Button(a.label) { e.defaultAction = a } }
                    }
                    .fixedSize()
                    Spacer()
                    if hasExited { Button("Clear exited") { e.clearExited() }.buttonStyle(.link) }
                }
                .font(.callout)
            }
        }
    }

    private var hasExited: Bool {
        e.targets.contains { t in
            switch t.kind {
            case .pid: return e.livePIDs(t).isEmpty
            case .container: return e.liveContainer(t) == nil
            default: return false
            }
        }
    }

    private var addMenu: some View {
        Menu {
            Menu("Running App") {
                ForEach(e.runningApps, id: \.bundleID) { a in
                    Button(a.name) { e.addApp(bundleID: a.bundleID, name: a.name) }
                }
            }
            Button("Choose an App…") { e.chooseApp { e.addApp(bundleID: $0, name: $1) } }
            Menu("Docker Container") {
                if !e.dockerAvailable { Text("Docker isn't running") }
                else if e.containers.isEmpty { Text("No containers running") }
                ForEach(e.containers) { c in Button("\(c.name) — \(c.image)") { e.addContainer(c) } }
            }
            Divider()
            Button("Browse Processes…") { showPicker = true }
            Button("Process ID…") { addMode = .pid }
            Button("Process Name…") { addMode = .name }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .fixedSize()
    }

    // MARK: Saver Mode

    private var saverCard: some View {
        Card("Saver Mode", subtitle: "Save battery and give your agents the whole Mac. Opening the lid always puts everything back the way you had it.") {
            Menu(triggerLabel) {
                ForEach(SaverTrigger.allCases) { t in Button(t.label) { e.trigger = t } }
            }
            .fixedSize()
        } content: {
            RowStack {
                SwitchRow(icon: "pause.circle", title: "Pause other apps",
                          detail: "Freezes apps you haven't kept running. Terminal, VS Code and tmux are protected automatically when an agent runs inside them.",
                          isOn: $e.saver.pauseApps)
                Divider()
                SwitchRow(icon: "display", title: "Turn off the screen",
                          detail: "Also turns off external monitors.", isOn: $e.saver.displayOff)
                Divider()
                SwitchRow(icon: "dot.radiowaves.left.and.right", title: "Turn off Bluetooth", isOn: $e.saver.bluetoothOff)
                    .disabled(!Radios.bluetoothAvailable)
                Divider()
                SwitchRow(icon: "wifi.slash", title: "Turn off Wi‑Fi",
                          detail: e.saver.wifiOff ? "⚠︎ Online agents (Claude Code, Codex, Gemini…) will stop working." : "Only for offline work — most agents need the internet.",
                          isOn: $e.saver.wifiOff)
                Divider()
                SwitchRow(icon: "speaker.slash", title: "Mute the speakers",
                          detail: "Your Mac's built-in speakers.", isOn: $e.saver.muteSpeakers)
                Divider()
                SwitchRow(icon: "headphones", title: "Mute the headphone jack",
                          detail: "Wired headphones or speakers plugged into the audio jack.", isOn: $e.saver.muteHeadphones)
                Divider()
                SwitchRow(icon: "battery.25", title: "Low Power Mode on battery",
                          detail: e.passwordless ? nil : "Needs the one-time setup above.",
                          isOn: $e.saver.lowPowerOnBattery)
                    .disabled(!e.passwordless)
                Divider()
                SwitchRow(icon: "display.2", title: "External monitor means I'm still using it",
                          detail: "With the lid closed and a monitor plugged in, Saver Mode stays off.",
                          isOn: $e.dockedCountsAsInUse)
                Divider()
                neverPauseRow
                if !e.restore.pausedApps.isEmpty {
                    Divider()
                    ControlRow(icon: "pause.fill", title: "Paused right now",
                               detail: e.restore.pausedApps.map(\.name).joined(separator: ", ")) {
                        Button("Resume All") { e.snoozeSaver() }
                    }
                }
            }
            .disabled(e.trigger == .off)
            .opacity(e.trigger == .off ? 0.5 : 1)
        }
    }

    private var triggerLabel: String {
        switch e.trigger {
        case .off: "Off"
        case .lidClosed: "When the lid is closed"
        case .always: "Whenever it's awake"
        }
    }

    private var neverPauseRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            ControlRow(icon: "hand.raised", title: "Never pause",
                       detail: "e.g. the browser an agent controls") {
                Menu("Add App") {
                    ForEach(e.runningApps, id: \.bundleID) { a in
                        Button(a.name) { if !e.neverPause.contains(a.bundleID) { e.neverPause.append(a.bundleID) } }
                    }
                }
                .fixedSize()
            }
            if !e.neverPause.isEmpty {
                HStack(spacing: 6) {
                    ForEach(e.neverPause, id: \.self) { b in
                        HStack(spacing: 4) {
                            Text(appName(b))
                            Button { e.neverPause.removeAll { $0 == b } } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless)
                        }
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                .padding(.leading, 30)
            }
        }
    }

    private func appName(_ bundleID: String) -> String {
        e.runningApps.first { $0.bundleID == bundleID }?.name ?? bundleID
    }

    // MARK: Battery

    private var batteryCard: some View {
        Card("Battery", subtitle: batteryLine) {
            RowStack {
                SwitchRow(icon: "powerplug", title: "Only while plugged in",
                          detail: "Unplug and your Mac can sleep. Plug back in and AlwaysUp picks up again.",
                          isOn: $e.onlyWhileCharging)
                Divider()
                ControlRow(icon: "battery.25", title: "Let the Mac sleep when the battery is low",
                           detail: "A safety net for every session and kept item.") {
                    HStack(spacing: 8) {
                        if e.batteryGuard {
                            Menu("Below \(e.batteryThreshold)%") {
                                ForEach([5, 10, 15, 20, 30, 50], id: \.self) { p in Button("\(p)%") { e.batteryThreshold = p } }
                            }
                            .fixedSize()
                        }
                        Toggle("", isOn: $e.batteryGuard).toggleStyle(.switch).labelsHidden()
                    }
                }
            }
        }
    }

    private var batteryLine: String? {
        guard let b = e.battery else { return nil }
        return "\(b.percent)% · \(b.onBattery ? "on battery" : "plugged in")"
    }

    // MARK: General

    private var generalCard: some View {
        Card("General") {
            RowStack {
                SwitchRow(icon: "bolt.horizontal", title: "Stay awake while kept items run",
                          detail: "Turn off to only stay awake when you press Keep Awake.",
                          isOn: $e.awakeForTargets)
                Divider()
                SwitchRow(icon: "power", title: "Open at login",
                          isOn: Binding(get: { e.launchAtLogin }, set: { e.launchAtLogin = $0 }))
                Divider()
                SwitchRow(icon: "key", title: "Switch without a password",
                          detail: "Allows only the exact sleep and Low Power Mode commands AlwaysUp needs.",
                          isOn: Binding(get: { e.passwordless }, set: { _ in e.togglePasswordless() }))
                Divider()
                ControlRow(icon: "moon.zzz", title: "Let the Mac sleep when kept items go idle",
                           detail: "Idle = using almost no CPU, like an agent waiting at its prompt. It holds the Mac awake again as soon as it's busy.") {
                    Menu(e.idleRelease.map { "After \(formatDuration($0))" } ?? "Off") {
                        Button("Off") { e.idleRelease = nil }
                        Divider()
                        ForEach([300.0, 600, 900, 1800, 3600], id: \.self) { d in
                            Button("After \(formatDuration(d))") { e.idleRelease = d }
                        }
                    }
                    .fixedSize()
                }
                Divider()
                SwitchRow(icon: "thermometer.medium", title: "Let the Mac sleep if it overheats with the lid closed",
                          detail: "A closed Mac can't cool as well — don't run heavy agents inside a bag.",
                          isOn: $e.thermalGuard)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    RowLabel(icon: "iphone", title: "Send notifications to my phone",
                             detail: "Paste an ntfy topic address (e.g. https://ntfy.sh/a-name-only-you-know). Used while the lid is closed. The names of your kept items are sent to that address.")
                    HStack {
                        TextField("https://ntfy.sh/…", text: $e.pushURL).textFieldStyle(.roundedBorder)
                        Button("Test") { e.testPush() }.disabled(!Push.isValid(e.pushURL))
                    }
                    .padding(.leading, 30)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    RowLabel(icon: "text.badge.plus", title: "Also list these as agents",
                             detail: "Program names, separated by commas — for agents AlwaysUp doesn't know yet.")
                    TextField("e.g. my-agent, devin", text: $agentsText)
                        .textFieldStyle(.roundedBorder)
                        .padding(.leading, 30)
                        .onAppear { agentsText = e.customAgents.joined(separator: ", ") }
                        .onChange(of: agentsText) { text in
                            let names = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                            if names != e.customAgents { e.customAgents = names }
                        }
                }
            }
        }
    }

    private func shortAction(_ a: ExpireAction) -> String {
        switch a {
        case .release: "let Mac sleep"
        case .pause: "pause it"
        case .quit: "quit it"
        }
    }
}

// MARK: - One kept item

struct TargetRow: View {
    @ObservedObject var e: Engine
    let t: Target
    @State private var editing = false

    private var icon: String {
        switch t.kind {
        case .pid: "terminal"
        case .app: "macwindow"
        case .processName: "text.magnifyingglass"
        case .container: "shippingbox"
        case .agent: "sparkles"
        }
    }

    private var dot: Color {
        if t.isTimerPaused || t.expired { return .orange }
        return e.isRunning(t) ? .green : .secondary.opacity(0.5)
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 20)
                Circle().fill(dot).frame(width: 7, height: 7).offset(x: 3, y: 2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(t.displayName)
                Text(e.statusText(t)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { editing = true } label: {
                Chip(text: e.limitText(t), icon: "timer")
            }
            .buttonStyle(.plain)
            .help("Change the time limit")
            .popover(isPresented: $editing, arrowEdge: .bottom) { TargetEditor(e: e, id: t.id) }

            if t.isTimerPaused { Button("Resume") { e.resumeTarget(t.id) } }

            Menu {
                Button("Restart Timer") { e.restartTarget(t.id) }
                Button("Change Time Limit…") { editing = true }
                Divider()
                Button("Stop Keeping It Running") { e.removeTarget(t.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

struct TargetEditor: View {
    @ObservedObject var e: Engine
    let id: UUID

    var body: some View {
        if let i = e.targets.firstIndex(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 14) {
                Text(e.targets[i].displayName).font(.headline)
                ControlRow(icon: "timer", title: "Keep running for") {
                    DurationPicker(value: $e.targets[i].limit)
                }
                ControlRow(icon: "flag.checkered", title: "When time's up") {
                    Menu(e.targets[i].action.label) {
                        ForEach(ExpireAction.allCases) { a in Button(a.label) { e.targets[i].action = a } }
                    }
                    .fixedSize()
                }
                HStack {
                    Text("Counts from when it starts running, or from when you restart the timer.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart Timer") { e.restartTarget(id) }
                }
            }
            .padding(16)
            .frame(width: 440)
        }
    }
}

// MARK: - Add by PID / name

struct AddSheet: View {
    @ObservedObject var e: Engine
    let mode: AdvancedView.AddMode
    let done: () -> Void
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode == .pid ? "Keep a process running" : "Keep every process with a name running").font(.headline)
            Text(mode == .pid
                 ? "Enter the process ID (find it in Activity Monitor, or with `ps` / `pgrep`)."
                 : "Matches every process with this exact name, including ones that start later — e.g. python3, node, claude.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(mode == .pid ? "e.g. 4321" : "e.g. python3", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            if let err = error { Text(err).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Add", action: add).keyboardShortcut(.defaultAction).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func add() {
        if mode == .pid {
            error = e.addPID(text)
            if error == nil { done() }
        } else {
            e.addName(text)
            done()
        }
    }
}

// MARK: - Process browser

struct ProcessPicker: View {
    @ObservedObject var e: Engine
    let done: () -> Void
    @State private var query = ""

    private var list: [ProcInfo] {
        let me = getuid()
        return e.procs
            .filter { $0.uid == me && (query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) || String($0.pid).hasPrefix(query)) }
            .sorted { ($0.displayName.lowercased(), $0.pid) < ($1.displayName.lowercased(), $1.pid) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a process").font(.headline)
            HStack {
                TextField("Search by name or PID", text: $query).textFieldStyle(.roundedBorder)
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
            List(list) { p in
                HStack {
                    Text(p.displayName)
                    Text("PID \(String(p.pid))").foregroundStyle(.secondary)
                    Spacer()
                    Text(formatDuration(e.now.timeIntervalSince(p.start))).foregroundStyle(.secondary).font(.caption)
                    Button("Add") { e.addProc(p) }
                }
            }
        }
        .padding(16)
        .frame(width: 560, height: 500)
    }
}
