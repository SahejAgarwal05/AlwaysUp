// Engine.swift — all state and logic: keep-awake, kept items (targets), Saver Mode, persistence.

import AppKit
import Combine
import ServiceManagement
import UserNotifications

// MARK: - Model

enum TargetKind: Codable, Hashable {
    case pid(Int32, name: String, start: Double)
    case app(bundleID: String, name: String)
    case processName(String)
    case container(id: String, name: String)
}

enum ExpireAction: String, Codable, CaseIterable, Identifiable {
    case release, pause, quit
    var id: String { rawValue }
    var label: String {
        switch self {
        case .release: "Stop keeping Mac awake for it"
        case .pause: "Pause it (resume later)"
        case .quit: "Quit it"
        }
    }
}

struct Target: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: TargetKind
    var limit: TimeInterval?          // nil = unlimited
    var startedAt = Date()
    var action: ExpireAction = .release
    var expired = false
    var pausedPIDs: [Int32] = []      // set when the timer paused it
    var containerPaused: Bool?        // set when the timer paused a Docker container
    var isTimerPaused: Bool { !pausedPIDs.isEmpty || containerPaused == true }

    var displayName: String {
        switch kind {
        case .pid(_, let n, _): n
        case .app(_, let n): n
        case .processName(let n): n
        case .container(_, let n): n
        }
    }
    var kindLabel: String {
        switch kind {
        case .pid(let p, _, _): "PID \(p)"
        case .app(let b, _): b
        case .processName: "any process with this name"
        case .container(let id, _): "Docker · \(id.prefix(12))"
        }
    }
}

enum SaverTrigger: String, Codable, CaseIterable, Identifiable {
    case off, lidClosed, always
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Never"
        case .lidClosed: "When the lid is closed"
        case .always: "Whenever the Mac is being kept awake"
        }
    }
}

struct SaverOptions: Codable, Equatable {
    var pauseApps = true
    var displayOff = true
    var bluetoothOff = false
    var wifiOff = false
    var lowPowerOnBattery = true
    var muteSpeakers = false
    var muteHeadphones = false
}

extension SaverOptions {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func b(_ k: CodingKeys, _ d: Bool) -> Bool { (try? c.decode(Bool.self, forKey: k)) ?? d }
        pauseApps = b(.pauseApps, true)
        displayOff = b(.displayOff, true)
        bluetoothOff = b(.bluetoothOff, false)
        wifiOff = b(.wifiOff, false)
        lowPowerOnBattery = b(.lowPowerOnBattery, true)
        muteSpeakers = b(.muteSpeakers, false)
        muteHeadphones = b(.muteHeadphones, false)
    }
}

struct PausedApp: Codable, Identifiable, Hashable {
    let pid: Int32
    let name: String
    let bundleID: String?
    let pids: [Int32]
    var id: Int32 { pid }
}

/// What Saver Mode changed, so it can be put back (also written to disk for crash recovery).
struct SaverRestore: Codable, Equatable {
    var pausedApps: [PausedApp] = []
    var bluetoothWasOn: Bool?
    var wifiWasOn: Bool?
    var lowPowerPrev: Int?
    var targetPausedPIDs: [Int32] = []
    /// Audio device UID → was it muted before Saver Mode muted it.
    var audioWasMuted: [String: Bool] = [:]
}

extension SaverRestore {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pausedApps = (try? c.decode([PausedApp].self, forKey: .pausedApps)) ?? []
        bluetoothWasOn = try? c.decodeIfPresent(Bool.self, forKey: .bluetoothWasOn)
        wifiWasOn = try? c.decodeIfPresent(Bool.self, forKey: .wifiWasOn)
        lowPowerPrev = try? c.decodeIfPresent(Int.self, forKey: .lowPowerPrev)
        targetPausedPIDs = (try? c.decode([Int32].self, forKey: .targetPausedPIDs)) ?? []
        audioWasMuted = (try? c.decode([String: Bool].self, forKey: .audioWasMuted)) ?? [:]
    }
}

private struct Saved: Codable {
    var targets: [Target] = []
    var manualDuration: TimeInterval?
    var trigger: SaverTrigger = .lidClosed
    var saver = SaverOptions()
    var awakeForTargets = true
    var batteryGuard = true
    var batteryThreshold = 20
    var neverPause: [String] = []
    var defaultLimit: TimeInterval?
    var defaultAction: ExpireAction = .release
    var dockedCountsAsInUse = true
    var manualUntilBattery: Int?
    var onlyWhileCharging = false
    var thermalGuard = true
    var idleRelease: TimeInterval?
    var pushURL = ""
    var customAgents: [String] = []
}

extension Saved {
    /// Tolerant decoding: missing keys (older versions) fall back to defaults instead of losing everything.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Saved()
        targets = (try? c.decode([Target].self, forKey: .targets)) ?? d.targets
        manualDuration = try? c.decodeIfPresent(TimeInterval.self, forKey: .manualDuration)
        trigger = (try? c.decode(SaverTrigger.self, forKey: .trigger)) ?? d.trigger
        saver = (try? c.decode(SaverOptions.self, forKey: .saver)) ?? d.saver
        awakeForTargets = (try? c.decode(Bool.self, forKey: .awakeForTargets)) ?? d.awakeForTargets
        batteryGuard = (try? c.decode(Bool.self, forKey: .batteryGuard)) ?? d.batteryGuard
        batteryThreshold = (try? c.decode(Int.self, forKey: .batteryThreshold)) ?? d.batteryThreshold
        neverPause = (try? c.decode([String].self, forKey: .neverPause)) ?? d.neverPause
        defaultLimit = try? c.decodeIfPresent(TimeInterval.self, forKey: .defaultLimit)
        defaultAction = (try? c.decode(ExpireAction.self, forKey: .defaultAction)) ?? d.defaultAction
        dockedCountsAsInUse = (try? c.decode(Bool.self, forKey: .dockedCountsAsInUse)) ?? d.dockedCountsAsInUse
        manualUntilBattery = try? c.decodeIfPresent(Int.self, forKey: .manualUntilBattery)
        onlyWhileCharging = (try? c.decode(Bool.self, forKey: .onlyWhileCharging)) ?? d.onlyWhileCharging
        thermalGuard = (try? c.decode(Bool.self, forKey: .thermalGuard)) ?? d.thermalGuard
        idleRelease = try? c.decodeIfPresent(TimeInterval.self, forKey: .idleRelease)
        pushURL = (try? c.decode(String.self, forKey: .pushURL)) ?? d.pushURL
        customAgents = (try? c.decode([String].self, forKey: .customAgents)) ?? d.customAgents
    }
}

/// Why the Mac is awake — written to disk so a relaunch after a crash picks up the same session
/// instead of turning it into an unlimited one.
private struct Session: Codable, Equatable {
    var manualActive: Bool
    var manualUntil: Date?
}

/// What happened between closing the lid and opening it again.
struct AwaySummary: Equatable {
    var away: TimeInterval
    var awake: TimeInterval
    var batteryFrom: Int?
    var batteryTo: Int?
    var events: [String]

    var text: String {
        var parts = ["Kept awake for \(formatDuration(awake)) of \(formatDuration(away))"]
        if let a = batteryFrom, let b = batteryTo { parts.append("battery \(a)% → \(b)%") }
        var seen = Set<String>()
        parts += events.filter { seen.insert($0).inserted }.prefix(6)
        return parts.joined(separator: " · ")
    }
}

private struct AwaySession {
    var start: Date
    var last: Date
    var awake: TimeInterval = 0
    var battery: Int?
    var events: [String] = []
}

/// CPU use of one kept item's process tree, sampled each tick, to tell "working" from "idle".
private struct Activity {
    var cpu: [Int32: Double] = [:]
    var at: Date
    var lastActive: Date
    /// The agent itself said it's waiting for you (`AlwaysUp done`). Cleared when it gets busy again.
    var done = false
    var needsBaseline = true
}

// MARK: - Engine

@MainActor
final class Engine: ObservableObject {
    static let shared = Engine()

    let sys: System
    private let defaults: UserDefaults
    private let supportDir: URL

    // Settings (persisted)
    @Published var targets: [Target] = [] { didSet { changed() } }
    @Published var manualDuration: TimeInterval? { didSet { changed() } }
    @Published var trigger: SaverTrigger = .lidClosed { didSet { changed() } }
    @Published var saver = SaverOptions() { didSet { changed() } }
    @Published var awakeForTargets = true { didSet { changed() } }
    @Published var batteryGuard = true { didSet { changed() } }
    @Published var batteryThreshold = 20 { didSet { changed() } }
    @Published var neverPause: [String] = [] { didSet { changed() } }
    @Published var defaultLimit: TimeInterval? { didSet { changed() } }
    @Published var defaultAction: ExpireAction = .release { didSet { changed() } }
    @Published var dockedCountsAsInUse = true { didSet { changed() } }
    /// Manual keep-awake ends when the battery drops to this % (instead of after a time).
    @Published var manualUntilBattery: Int? { didSet { changed() } }
    /// Only keep the Mac awake while it's plugged in.
    @Published var onlyWhileCharging = false { didSet { changed() } }
    /// Let the Mac sleep if it gets hot while you're away (lid closed, possibly in a bag).
    @Published var thermalGuard = true { didSet { changed() } }
    /// A kept item that has used almost no CPU for this long stops holding the Mac awake. nil = off.
    @Published var idleRelease: TimeInterval? { didSet { changed() } }
    /// ntfy-style URL that also receives notifications while the lid is closed. "" = off.
    @Published var pushURL = "" { didSet { changed() } }
    /// Extra process names to list as agents.
    @Published var customAgents: [String] = [] { didSet { agentCache = [:]; changed() } }

    // Live state
    @Published private(set) var manualActive = false
    @Published private(set) var manualUntil: Date?
    @Published private(set) var awake = false
    @Published private(set) var saverActive = false
    @Published private(set) var lidClosed = false
    @Published private(set) var containers: [Container] = []
    @Published private(set) var dockerAvailable = false

    // Test hooks (used by the self-test; nil = read the real hardware).
    var lidOverride: Bool?
    var externalDisplayOverride: Bool?
    var batteryOverride: Battery?
    var thermalOverride: ProcessInfo.ThermalState?
    /// What `AlwaysUp simulate` is currently pretending ("" = nothing), shown in the window.
    @Published private(set) var simulating = ""
    @Published private(set) var externalDisplay = false
    /// Lid closed and nobody is using an external monitor → you've walked away.
    var away: Bool { lidClosed && !(dockedCountsAsInUse && externalDisplay) }
    @Published private(set) var battery: Battery?
    @Published private(set) var procs: [ProcInfo] = []
    @Published private(set) var detected: [DetectedAgent] = []
    @Published private(set) var now = Date()
    @Published private(set) var restore = SaverRestore()
    @Published private(set) var batteryTripped = false
    @Published private(set) var thermalTripped = false
    @Published private(set) var passwordless = false
    @Published private(set) var lastAway: AwaySummary?
    @Published var authBlocked = false
    @Published var saverSnoozed = false

    /// While the window is open the engine looks more often (countdowns, live lists).
    var windowVisible = false { didSet { if windowVisible != oldValue { scheduleNext(); if windowVisible { tickSoon() } } } }
    var onUpdate: (() -> Void)?

    private var procByPID: [Int32: ProcInfo] = [:]
    private var children: [Int32: [Int32]] = [:]
    private var apps: [AppInfo] = []
    private var thermal: ProcessInfo.ThermalState = .nominal
    private var caffeinate: Process?
    private var watchdog: Process?
    private var watchdogPipe: Pipe?
    private var loaded = false
    private var applyQueued = false
    private var ticks = 0
    private var lastLid = false
    private var lastLidClosed = false
    private var wasAwake = false
    /// After restoring radios, double-check a few seconds later that they really came back.
    private var verifyRestore: (at: Date, bluetooth: Bool, wifi: Bool)?
    private let myUID = getuid()

    // Polling
    private var timer: Timer?
    private var interval: TimeInterval = 0
    private var pollInFlight = false
    private var ticking = false
    /// Counts ticks, so a background reading that was overtaken by a newer tick can be thrown away.
    private var tickSeq = 0
    private var soonQueued = false
    private let pollQueue = DispatchQueue(label: "local.alwaysup.poll", qos: .utility)

    // Per-item bookkeeping (not saved)
    private var presence: [UUID: Bool] = [:]
    private var activity: [UUID: Activity] = [:]
    private var idleNotified: Set<UUID> = []
    private var agentCache: [Int32: (start: Date, path: String, hit: (name: String, isApp: Bool, command: String)?)] = [:]
    private var awaySession: AwaySession?
    private var lastSession: Session?
    /// Stay awake a few more seconds after sending a phone notification, so it gets out before the Mac sleeps.
    private var pushHold: Date?

    private static let systemSafe: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.systemuiserver", "com.apple.controlcenter",
        "com.apple.loginwindow", "com.apple.notificationcenterui", "com.apple.Spotlight",
        "com.apple.ActivityMonitor", "com.apple.systempreferences", "com.apple.SecurityAgent",
        "local.alwaysup",
    ]

    private var restoreFile: URL { supportDir.appendingPathComponent("restore.json") }
    private var sessionFile: URL { supportDir.appendingPathComponent("session.json") }
    /// Plain list of paused PIDs for the watchdog (a shell script — it can't read JSON).
    private var pausedPIDsFile: URL { supportDir.appendingPathComponent("paused.pids") }

    init(system: System = System(), defaults: UserDefaults = .standard, supportDir: URL? = nil) {
        sys = system
        self.defaults = defaults
        self.supportDir = supportDir ?? Paths.supportDir
        try? FileManager.default.createDirectory(at: self.supportDir, withIntermediateDirectories: true)
        now = system.now()
        load()
        recoverFromCrash()
        passwordless = sys.passwordlessReady()
        if sys.isSleepDisabled() {
            // Still disabled from a previous run that didn't exit cleanly → carry on with the same session.
            awake = true
            if let d = try? Data(contentsOf: sessionFile), let s = try? JSONDecoder().decode(Session.self, from: d) {
                manualActive = s.manualActive
                manualUntil = s.manualUntil
            } else {
                manualActive = true
            }
            startCaffeinate()
        } else {
            try? FileManager.default.removeItem(at: sessionFile)
        }
        loaded = true
        startWatchdog()
        tick()
        if sys.live {
            Events.start { [weak self] in self?.tickSoon() }
            if !Self.quiet { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = defaults.data(forKey: "state"),
              let s = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        let alive = Set(sys.procs().map(\.pid))
        targets = s.targets.compactMap { t in
            var t = t
            t.pausedPIDs = []
            if case .pid(let p, _, _) = t.kind, !alive.contains(p) { return nil }  // gone after reboot/exit
            return t
        }
        manualDuration = s.manualDuration
        trigger = s.trigger
        saver = s.saver
        awakeForTargets = s.awakeForTargets
        batteryGuard = s.batteryGuard
        batteryThreshold = s.batteryThreshold
        neverPause = s.neverPause
        defaultLimit = s.defaultLimit
        defaultAction = s.defaultAction
        dockedCountsAsInUse = s.dockedCountsAsInUse
        manualUntilBattery = s.manualUntilBattery
        onlyWhileCharging = s.onlyWhileCharging
        thermalGuard = s.thermalGuard
        idleRelease = s.idleRelease
        pushURL = s.pushURL
        customAgents = s.customAgents
    }

    private func save() {
        let s = Saved(targets: targets, manualDuration: manualDuration, trigger: trigger, saver: saver,
                      awakeForTargets: awakeForTargets, batteryGuard: batteryGuard,
                      batteryThreshold: batteryThreshold, neverPause: neverPause,
                      defaultLimit: defaultLimit, defaultAction: defaultAction,
                      dockedCountsAsInUse: dockedCountsAsInUse,
                      manualUntilBattery: manualUntilBattery, onlyWhileCharging: onlyWhileCharging,
                      thermalGuard: thermalGuard, idleRelease: idleRelease, pushURL: pushURL,
                      customAgents: customAgents)
        if let d = try? JSONEncoder().encode(s) { defaults.set(d, forKey: "state") }
    }

    private func saveRestore() {
        if let d = try? JSONEncoder().encode(restore) { try? d.write(to: restoreFile, options: .atomic) }
        let pids = restore.pausedApps.flatMap(\.pids) + restore.targetPausedPIDs
        try? pids.map(String.init).joined(separator: "\n").write(to: pausedPIDsFile, atomically: true, encoding: .utf8)
    }

    private func saveSession() {
        let s = awake ? Session(manualActive: manualActive, manualUntil: manualUntil) : nil
        guard s != lastSession else { return }
        lastSession = s
        if let s, let d = try? JSONEncoder().encode(s) { try? d.write(to: sessionFile, options: .atomic) }
        else { try? FileManager.default.removeItem(at: sessionFile) }
    }

    /// If AlwaysUp crashed while Saver Mode was on, un-pause apps and turn radios back on.
    func recoverFromCrash() {
        guard let d = try? Data(contentsOf: restoreFile),
              let r = try? JSONDecoder().decode(SaverRestore.self, from: d) else { return }
        restore = r
        r.targetPausedPIDs.forEach { sys.signal($0, SIGCONT) }
        restore.targetPausedPIDs = []
        exitSaver()
    }

    private func changed() {
        guard loaded else { return }
        save()
        guard !applyQueued else { return }
        applyQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.applyQueued = false
            self?.apply()
        }
    }

    // MARK: Watchdog

    /// A tiny shell process that outlives a crash or `kill -9`. It blocks reading a pipe that only
    /// closes when AlwaysUp dies; then it resumes anything left paused and lets the Mac sleep again.
    /// A clean quit kills it first, so it only ever acts when AlwaysUp disappeared unexpectedly.
    private func startWatchdog() {
        guard sys.live else { return }
        let script = """
        read _
        if [ -f "$1" ]; then for p in $(cat "$1"); do kill -CONT "$p" 2>/dev/null; done; fi
        /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "alwaysup-watchdog", pausedPIDsFile.path]
        let pipe = Pipe()
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        watchdog = p
        watchdogPipe = pipe     // keep our end open for as long as we live
    }

    // MARK: Process bookkeeping

    private func setProcs(_ list: [ProcInfo]) {
        if list != procs { procs = list }
        procByPID = Dictionary(list.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var ch: [Int32: [Int32]] = [:]
        for p in list { ch[p.ppid, default: []].append(p.pid) }
        children = ch
    }

    func descendants(_ pid: Int32) -> [Int32] {
        var out: [Int32] = [], stack = children[pid] ?? []
        while let p = stack.popLast() {
            out.append(p)
            stack.append(contentsOf: children[p] ?? [])
        }
        return out
    }

    func livePIDs(_ t: Target) -> [Int32] {
        switch t.kind {
        case .pid(let p, _, let start):
            guard let info = procByPID[p], abs(info.start.timeIntervalSince1970 - start) < 2 else { return [] }
            return [p]
        case .app(let b, _):
            return apps.filter { $0.bundleID == b }.map(\.pid)
        case .container:
            return []
        case .processName(let n):
            let l = n.lowercased()
            return procs.filter { $0.uid == myUID && ($0.displayName.lowercased() == l || $0.comm.lowercased() == l) }
                .map(\.pid)
        }
    }

    var onBattery: Bool { battery?.onBattery ?? false }
    /// "Only while plugged in" is on, something wants the Mac awake, but it's unplugged.
    var waitingForCharger: Bool {
        onlyWhileCharging && onBattery && (manualActive || (awakeForTargets && holdingCount > 0))
    }

    /// Matches by ID, or by name so containers recreated by `docker compose up` still count.
    func liveContainer(_ t: Target) -> Container? {
        guard case .container(let id, let name) = t.kind else { return nil }
        return containers.first { $0.id == id } ?? containers.first { $0.name == name }
    }

    func isRunning(_ t: Target) -> Bool {
        if case .container = t.kind { return liveContainer(t)?.isRunning ?? false }
        return !livePIDs(t).isEmpty
    }

    /// Running but doing nothing: the agent said it's waiting for you, or it has used almost no CPU
    /// for the "idle" time chosen in settings.
    func isIdle(_ t: Target) -> Bool {
        guard let a = activity[t.id] else { return false }
        if a.done { return true }
        guard let limit = idleRelease else { return false }
        return now.timeIntervalSince(a.lastActive) >= limit
    }

    func isHolding(_ t: Target) -> Bool { !t.expired && !t.isTimerPaused && isRunning(t) && !isIdle(t) }

    func refreshContainers() {
        if let list = sys.dockerList() { containers = list; dockerAvailable = true }
        else { containers = []; dockerAvailable = false }
    }

    func isMarked(_ c: Container) -> Bool {
        targets.contains { if case .container(let id, let name) = $0.kind { return id == c.id || name == c.name }; return false }
    }

    func addContainer(_ c: Container) { add(.container(id: c.id, name: c.name)) }

    func unmark(_ c: Container) {
        for t in targets where isMarked(c) {
            if case .container(let id, let name) = t.kind, id == c.id || name == c.name { removeTarget(t.id) }
        }
    }
    var holdingCount: Int { targets.filter(isHolding).count }

    /// Reads each process's command line once and remembers the answer until the process changes.
    func scanAgents() {
        var found: [Int32: DetectedAgent] = [:]
        var cache: [Int32: (start: Date, path: String, hit: (name: String, isApp: Bool, command: String)?)] = [:]
        for p in procs where p.uid == myUID {
            let hit: (name: String, isApp: Bool, command: String)?
            if let c = agentCache[p.pid], c.start == p.start, c.path == p.path {
                hit = c.hit
            } else {
                let args = sys.args(p.pid)
                hit = Agents.match(p, args: args, custom: customAgents)
                    .map { (name: $0.name, isApp: $0.isApp, command: args.joined(separator: " ")) }
            }
            cache[p.pid] = (p.start, p.path, hit)
            if let h = hit { found[p.pid] = DetectedAgent(agent: h.name, proc: p, command: h.command, isApp: h.isApp) }
        }
        agentCache = cache
        // Hide sub-processes of an agent that was already found (e.g. claude → claude).
        let list = found.values
            .filter { a in found[a.proc.ppid]?.agent != a.agent }
            .sorted { $0.proc.start < $1.proc.start }
        if list != detected { detected = list }
    }

    /// Fresh process list + agents, for the moment the menu opens.
    func refreshForMenu() {
        setProcs(sys.procs())
        apps = sys.apps()
        scanAgents()
    }

    func isMarked(_ a: DetectedAgent) -> Bool { targets.contains { livePIDs($0).contains(a.proc.pid) } }

    // MARK: Main loop

    /// Saver Mode has frozen the Docker runtime — its socket would accept our call and never answer.
    private var dockerRuntimePaused: Bool {
        restore.pausedApps.contains {
            Docker.runtimeBundleIDs.contains($0.bundleID ?? "") || Docker.runtimeProcessNames.contains($0.name)
        }
    }

    /// Look at everything now, on the calling (main) thread.
    func tick() { tick(sys.snapshot(!dockerRuntimePaused)) }

    /// Gather the slow readings (process list, Docker socket…) off the main thread, then act on them.
    func tickAsync() {
        guard !pollInFlight else { return }
        pollInFlight = true
        let snapshot = sys.snapshot
        let docker = !dockerRuntimePaused
        let seq = tickSeq
        pollQueue.async {
            let s = snapshot(docker)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.pollInFlight = false
                    if seq == self.tickSeq { self.tick(s) }     // otherwise it's already out of date
                }
            }
        }
    }

    /// Something changed (lid, battery, an app launched…) — look again in a moment.
    func tickSoon() {
        guard sys.live, !soonQueued else { return }
        soonQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.soonQueued = false
            self?.tickAsync()
        }
    }

    /// Lid, battery and app events arrive as notifications, so the regular look can be slow:
    /// every 2s with the window open, 10s while there's something to watch, otherwise 30s.
    private func scheduleNext() {
        guard sys.live else { return }
        let want: TimeInterval = windowVisible ? 2 : (awake || manualActive || !targets.isEmpty ? 10 : 30)
        guard want != interval || timer == nil else { return }
        interval = want
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: want, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickAsync() }
        }
        t.tolerance = want * 0.2
        timer = t
    }

    func tick(_ s: Snapshot) {
        guard !ticking else { return }      // never run one tick inside another
        ticking = true
        defer { ticking = false }
        tickSeq += 1
        let before = now
        now = sys.now()
        setProcs(s.procs)
        apps = sys.apps()
        lidClosed = lidOverride ?? s.lidClosed
        externalDisplay = externalDisplayOverride ?? s.externalDisplay
        if s.dockerPolled {
            let list = s.containers ?? []
            if list != containers { containers = list }
            if dockerAvailable != (s.containers != nil) { dockerAvailable = s.containers != nil }
        }
        thermal = thermalOverride ?? s.thermal
        if away && !lastLid { saverSnoozed = false }   // walking away again re-arms Saver Mode
        lastLid = away
        if lastLidClosed && !lidClosed {
            // Lid opened → put everything back the way you had it, whatever the trigger.
            if trigger == .always { saverSnoozed = true }
            if saverActive || saverDirty { exitSaver() }
        }
        lastLidClosed = lidClosed
        if let v = verifyRestore, now >= v.at {
            verifyRestore = nil
            if v.bluetooth && !sys.bluetoothOn() { sys.setBluetooth(true) }
            if v.wifi && !sys.wifiOn() { sys.setWiFi(true) }
        }
        let b = batteryOverride ?? s.battery
        if b != battery { battery = b }
        trackAway(since: before)
        processRequests()
        ticks += 1
        if windowVisible || ticks % 6 == 1 { scanAgents() }

        trackTargets()
        checkTargetTimers()

        if manualActive, let u = manualUntil, now >= u {
            manualActive = false
            manualUntil = nil
            notify("Keep-awake timer finished", holdingCount > 0 ? "Still awake for \(holdingCount) kept item(s)." : "Your Mac can sleep again.")
        }

        if manualActive, let p = manualUntilBattery, let b = battery, b.onBattery, b.percent <= p {
            manualActive = false
            notify("Battery reached \(p)%", holdingCount > 0 ? "Still awake for \(holdingCount) kept item(s)." : "Your Mac can sleep again.")
        }

        let wantsAwake = manualActive || (awakeForTargets && holdingCount > 0)
        if let b = battery {
            if !b.onBattery { batteryTripped = false }
            else if batteryGuard, !batteryTripped, b.percent <= batteryThreshold, wantsAwake {
                batteryTripped = true
                manualActive = false
                notify("AlwaysUp turned off", "Battery at \(b.percent)% — your Mac can sleep to protect itself. Plug in to resume kept items.")
            }
        }

        if !away { thermalTripped = false }
        else if thermalGuard, !thermalTripped, thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue, wantsAwake {
            thermalTripped = true
            notify("AlwaysUp turned off", "Your Mac got too hot with the lid closed — letting it sleep to cool down.")
        }

        apply()
        scheduleNext()
    }

    /// Keeps a short record from the moment you walk away until you're back, for the "while you were away" note.
    private func trackAway(since before: Date) {
        if away {
            if awaySession == nil, awake {
                awaySession = AwaySession(start: now, last: now, battery: battery?.percent)
            } else if var s = awaySession {
                if awake { s.awake += min(max(0, now.timeIntervalSince(s.last)), 60) }
                s.last = now
                awaySession = s
            }
        } else if let s = awaySession {
            awaySession = nil
            guard s.awake >= 60 else { return }
            let sum = AwaySummary(away: now.timeIntervalSince(s.start), awake: s.awake, batteryFrom: s.battery,
                                  batteryTo: battery?.percent, events: s.events)
            lastAway = sum
            notify("While you were away", sum.text, push: false)
        }
    }

    func dismissAway() { lastAway = nil }

    /// Requests dropped by `AlwaysUp run|done|busy`.
    private func processRequests() {
        let dir = Paths.requests(in: supportDir)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]), !files.isEmpty else { return }
        for f in files {
            guard let d = try? Data(contentsOf: f), let r = try? JSONDecoder().decode(Request.self, from: d) else {
                try? FileManager.default.removeItem(at: f)
                continue
            }
            var handled = true
            switch r.cmd {
            case "keep":
                if let pid = r.pids.first, let p = procByPID[pid] {
                    add(.pid(pid, name: r.name ?? p.displayName, start: p.start.timeIntervalSince1970),
                        limit: r.limit.map { .some($0) }, action: r.action)
                } else {
                    handled = false     // not in the process list yet — try again next time
                }
            case "done", "busy":
                let pids = Set(r.pids)
                for t in targets where !pids.isDisjoint(with: livePIDs(t)) {
                    if r.cmd == "done" {
                        activity[t.id] = Activity(at: now, lastActive: now, done: true)
                    } else {
                        activity[t.id] = Activity(at: now, lastActive: now)
                        idleNotified.remove(t.id)
                    }
                }
            case "simulate": simulate(r.sim ?? [:])
            default: break
            }
            let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if handled || Date().timeIntervalSince(modified ?? .distantPast) > 30 {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    /// `AlwaysUp simulate …`: pretend the lid, monitor, battery or temperature is different, to try
    /// the app out at a desk. Nothing is saved; quitting the app (or `simulate off`) ends it.
    private func simulate(_ v: [String: String]) {
        if v.isEmpty {
            lidOverride = nil; externalDisplayOverride = nil; batteryOverride = nil; thermalOverride = nil
        }
        if let x = v["lid"] { lidOverride = x == "real" ? nil : x == "closed" }
        if let x = v["display"] { externalDisplayOverride = x == "real" ? nil : (x == "yes" || x == "on") }
        if let x = v["battery"] {
            // "15" = on battery at 15%; "15+" = charging at 15%.
            let pct = Int(x.trimmingCharacters(in: CharacterSet(charactersIn: "+%")))
            batteryOverride = pct.map { Battery(onBattery: !x.contains("+"), percent: max(0, min(100, $0))) }
        }
        if let x = v["thermal"] { thermalOverride = x == "real" ? nil : (x == "hot" ? .serious : .nominal) }
        var parts: [String] = []
        if let l = lidOverride { parts.append("lid \(l ? "closed" : "open")") }
        if let d = externalDisplayOverride { parts.append(d ? "monitor attached" : "no monitor") }
        if let b = batteryOverride { parts.append("battery \(b.percent)%\(b.onBattery ? "" : " charging")") }
        if let t = thermalOverride { parts.append(t == .nominal ? "cool" : "hot") }
        simulating = parts.joined(separator: ", ")
        if sys.live { tickSoon() }
    }

    /// Notices kept items starting, finishing and going idle.
    private func trackTargets() {
        var ts = targets
        for i in ts.indices {
            let t = ts[i]
            let present: Bool
            if case .container = t.kind {
                guard dockerAvailable else { continue }     // can't tell right now
                present = liveContainer(t) != nil
            } else {
                present = !livePIDs(t).isEmpty
            }
            let was = presence[t.id]
            presence[t.id] = present
            guard let was, was != present else { continue }
            if present {
                // It started again → its time limit counts from now (not from when it was added).
                if case .pid = t.kind {} else if !t.isTimerPaused {
                    ts[i].startedAt = now
                    ts[i].expired = false
                }
                activity[t.id] = nil
            } else if !t.expired {
                switch t.kind {
                case .pid, .container: notify("\(t.displayName) finished", "It's no longer keeping your Mac awake.")
                default: break
                }
            }
        }
        if ts != targets { targets = ts }
        let ids = Set(targets.map(\.id))
        presence = presence.filter { ids.contains($0.key) }
        activity = activity.filter { ids.contains($0.key) }
        idleNotified.formIntersection(ids)

        sampleActivity()
        for t in targets {
            let idle = !t.expired && !t.isTimerPaused && isRunning(t) && isIdle(t)
            if !idle { idleNotified.remove(t.id); continue }
            guard idleNotified.insert(t.id).inserted, away else { continue }
            notify(activity[t.id]?.done == true ? "\(t.displayName) is waiting for you" : "\(t.displayName) is idle",
                   "It's no longer keeping your Mac awake.")
        }
    }

    /// Adds up the CPU each kept item's process tree used since the last look.
    /// More than ~1% of one core counts as "working".
    private func sampleActivity() {
        for t in targets {
            if case .container = t.kind { continue }
            let roots = livePIDs(t)
            guard !roots.isEmpty else { activity[t.id] = nil; continue }
            var cpu: [Int32: Double] = [:]
            for p in Set(roots.flatMap { [$0] + descendants($0) }) {
                if let c = sys.cpuTime(p) { cpu[p] = c }
            }
            guard var a = activity[t.id] else {
                activity[t.id] = Activity(cpu: cpu, at: now, lastActive: now, needsBaseline: false)
                continue
            }
            if a.needsBaseline {
                a.cpu = cpu; a.at = now; a.needsBaseline = false
                activity[t.id] = a
                continue
            }
            let dt = now.timeIntervalSince(a.at)
            guard dt >= 5 else { continue }     // too short a window to judge
            var used = 0.0
            for (p, c) in cpu { used += max(0, c - (a.cpu[p] ?? 0)) }
            if used > dt * 0.01 { a.lastActive = now; a.done = false }
            a.cpu = cpu
            a.at = now
            activity[t.id] = a
        }
    }

    private func checkTargetTimers() {
        var ts = targets
        var dockerChanged = false
        for i in ts.indices {
            let t = ts[i]
            let deadline = t.limit.map { t.startedAt.addingTimeInterval($0) }
            if t.expired {
                // Limit was raised / made unlimited after it expired → active again.
                if !t.isTimerPaused, deadline.map({ now < $0 }) ?? true { ts[i].expired = false }
                continue
            }
            guard let d = deadline, now >= d else { continue }
            ts[i].expired = true
            if let c = liveContainer(t) {
                switch t.action {
                case .release: break
                case .pause: if sys.dockerPause(c.id) { ts[i].containerPaused = true }
                case .quit: _ = sys.dockerStop(c.id)
                }
                notify("Time's up: \(t.displayName)", t.action.label + ".")
                dockerChanged = true
                continue
            }
            let pids = livePIDs(t)
            switch t.action {
            case .release: break
            case .pause:
                let all = pids.flatMap { [$0] + descendants($0) }
                all.forEach { sys.signal($0, SIGSTOP) }
                ts[i].pausedPIDs = all
            case .quit:
                if case .app(let b, _) = t.kind {
                    sys.terminateApp(b)
                } else {
                    pids.forEach { sys.signal($0, SIGTERM) }
                }
            }
            if !pids.isEmpty { notify("Time's up: \(t.displayName)", t.action.label + ".") }
        }
        if dockerChanged { refreshContainers() }    // show the paused / stopped state right away
        if ts != targets { targets = ts }
        let tp = targets.flatMap(\.pausedPIDs)
        if tp != restore.targetPausedPIDs { restore.targetPausedPIDs = tp; saveRestore() }
    }

    func apply() {
        let holding = awakeForTargets && holdingCount > 0
        var want = !batteryTripped && !thermalTripped && !waitingForCharger && (manualActive || holding)
        if awake, !want, let h = pushHold, sys.now() < h { want = true }    // let the phone notification get out
        var sleepAfter = false
        if want != awake && !authBlocked {
            if sys.setSleepDisabled(want, true) {
                awake = want
                want ? startCaffeinate() : stopCaffeinate()
                sleepAfter = !want && away
            } else {
                authBlocked = true
            }
        }

        if awake && !wasAwake { saverSnoozed = false }   // a fresh keep-awake session re-arms Saver Mode
        wasAwake = awake
        let saverWanted = awake && !saverSnoozed &&
            (trigger == .always || (trigger == .lidClosed && away))
        if saverWanted { enterOrUpdateSaver() } else if saverActive || saverDirty { exitSaver() }
        saveSession()
        // Lid already shut when we let go → macOS wouldn't sleep by itself until its idle timer fires.
        if sleepAfter { sys.sleepNow() }
        onUpdate?()
    }

    // MARK: Saver Mode

    private func enterOrUpdateSaver() {
        let firstTime = !saverActive
        saverActive = true

        if firstTime && saver.displayOff { sys.displaySleepNow() }

        // Bluetooth
        if saver.bluetoothOff, restore.bluetoothWasOn == nil, sys.bluetoothAvailable() {
            restore.bluetoothWasOn = sys.bluetoothOn()
            if sys.bluetoothOn() { sys.setBluetooth(false) }
        } else if !saver.bluetoothOff, let was = restore.bluetoothWasOn {
            if was { sys.setBluetooth(true) }
            restore.bluetoothWasOn = nil
        }

        // Wi-Fi
        if saver.wifiOff, restore.wifiWasOn == nil, sys.wifiAvailable() {
            restore.wifiWasOn = sys.wifiOn()
            if sys.wifiOn() { sys.setWiFi(false) }
        } else if !saver.wifiOff, let was = restore.wifiWasOn {
            if was { sys.setWiFi(true) }
            restore.wifiWasOn = nil
        }

        // Low Power Mode on battery
        if saver.lowPowerOnBattery, restore.lowPowerPrev == nil, passwordless {
            let prev = sys.batteryLowPower() ?? 0
            if prev == 1 || sys.setBatteryLowPower(1) { restore.lowPowerPrev = prev }
        } else if !saver.lowPowerOnBattery, let prev = restore.lowPowerPrev {
            if prev != 1 { _ = sys.setBatteryLowPower(prev) }
            restore.lowPowerPrev = nil
        }

        // Speakers / headphone jack
        for out in sys.audioOutputs() {
            let want = out.isHeadphones ? saver.muteHeadphones : saver.muteSpeakers
            if want, restore.audioWasMuted[out.uid] == nil, let muted = sys.isMuted(out.id) {
                restore.audioWasMuted[out.uid] = muted
                if !muted { sys.setMuted(out.id, true) }
            } else if !want, let was = restore.audioWasMuted[out.uid] {
                if !was { sys.setMuted(out.id, false) }
                restore.audioWasMuted[out.uid] = nil
            }
        }

        // Pause other apps
        let before = restore
        if saver.pauseApps { pauseOthers() } else { resumeApps() }
        if firstTime || restore != before { saveRestore() }
    }

    private var saverDirty: Bool {
        !restore.pausedApps.isEmpty || restore.bluetoothWasOn != nil || restore.wifiWasOn != nil ||
            restore.lowPowerPrev != nil || !restore.audioWasMuted.isEmpty
    }

    private func exitSaver() {
        saverActive = false
        resumeApps()
        let btBack = restore.bluetoothWasOn == true, wifiBack = restore.wifiWasOn == true
        if let was = restore.bluetoothWasOn { if was { sys.setBluetooth(true) }; restore.bluetoothWasOn = nil }
        if let was = restore.wifiWasOn { if was { sys.setWiFi(true) }; restore.wifiWasOn = nil }
        if btBack || wifiBack { verifyRestore = (sys.now().addingTimeInterval(4), btBack, wifiBack) }
        if !restore.audioWasMuted.isEmpty {
            let outs = sys.audioOutputs()
            for (uid, was) in restore.audioWasMuted where !was {
                if let o = outs.first(where: { $0.uid == uid }) { sys.setMuted(o.id, false) }
            }
            restore.audioWasMuted = [:]
        }
        if let prev = restore.lowPowerPrev { if prev != 1 { _ = sys.setBatteryLowPower(prev) }; restore.lowPowerPrev = nil }
        saveRestore()
    }

    /// Kept items, everything they spawned, and every process they run inside (Terminal, VS Code, tmux…).
    private func protectedPIDs() -> Set<Int32> {
        var s: Set<Int32> = []
        var roots = targets.filter { $0.pausedPIDs.isEmpty }.flatMap(livePIDs) + [getpid()]
        // A kept container needs its runtime (Docker Desktop / OrbStack / Colima VM) to keep running.
        if targets.contains(where: { if case .container = $0.kind { return !$0.isTimerPaused }; return false }) {
            roots += procs.filter { $0.uid == myUID && Docker.runtimeProcessNames.contains($0.displayName) }.map(\.pid)
            roots += apps.filter { Docker.runtimeBundleIDs.contains($0.bundleID ?? "") }.map(\.pid)
        }
        for p in roots {
            s.insert(p)
            var cur = procByPID[p]?.ppid ?? 0
            while cur > 1, s.insert(cur).inserted { cur = procByPID[cur]?.ppid ?? 0 }
            descendants(p).forEach { s.insert($0) }
        }
        return s
    }

    /// Helpers that work for an app but aren't its children — XPC services such as a browser's web
    /// content processes are started by launchd. Found the way Activity Monitor groups them: by the
    /// app "responsible" for them. App extensions are left alone (other apps may be waiting on them).
    private func helperPIDs(of app: AppInfo, among candidates: [ProcInfo]) -> [Int32] {
        let inside = app.bundlePath.map { $0 + "/" }
        return candidates.filter { c in
            guard c.pid != app.pid, !c.path.contains(".appex/") else { return false }
            guard c.path.contains(".xpc/") || (inside.map { c.path.hasPrefix($0) } ?? false) else { return false }
            return sys.responsible(c.pid) == app.pid
        }.map(\.pid)
    }

    private func pauseOthers() {
        let prot = protectedPIDs()
        // Un-pause anything that has since become protected or allowed.
        for app in restore.pausedApps where prot.contains(app.pid) || neverPause.contains(app.bundleID ?? "") {
            app.pids.forEach { sys.signal($0, SIGCONT) }
            restore.pausedApps.removeAll { $0.pid == app.pid }
        }
        let already = Set(restore.pausedApps.map(\.pid))
        let regular = apps.filter(\.regular)
        let appPIDs = Set(regular.map(\.pid))
        var candidates: [ProcInfo]?
        for app in regular {
            let pid = app.pid
            let b = app.bundleID ?? ""
            if prot.contains(pid) || already.contains(pid) || neverPause.contains(b) || Self.systemSafe.contains(b) { continue }
            if candidates == nil {
                candidates = procs.filter { $0.uid == myUID && $0.ppid == 1 && !appPIDs.contains($0.pid) }
            }
            let helpers = helperPIDs(of: app, among: candidates ?? [])
            var seen = Set<Int32>()
            let group = ([pid] + descendants(pid) + helpers.flatMap { [$0] + descendants($0) })
                .filter { !prot.contains($0) && seen.insert($0).inserted }
            group.forEach { sys.signal($0, SIGSTOP) }
            restore.pausedApps.append(PausedApp(pid: pid, name: app.name.isEmpty ? b : app.name, bundleID: b, pids: group))
        }
    }

    private func resumeApps() {
        for app in restore.pausedApps { app.pids.forEach { sys.signal($0, SIGCONT) } }
        restore.pausedApps = []
    }

    /// "Resume everything now" — stays off until the lid is next closed.
    func snoozeSaver() {
        saverSnoozed = true
        apply()
    }

    // MARK: Caffeinate

    private func startCaffeinate() {
        guard sys.live else { return }
        caffeinate?.terminate()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-ims", "-w", "\(getpid())"]   // dies with us
        try? p.run()
        caffeinate = p
    }

    private func stopCaffeinate() {
        caffeinate?.terminate()
        caffeinate = nil
    }

    // MARK: User actions

    func startManual(_ duration: TimeInterval?? = .none) {
        if case .some(let d) = duration { manualDuration = d; manualUntilBattery = nil }
        batteryTripped = false
        thermalTripped = false
        authBlocked = false
        manualActive = true
        manualUntil = manualDuration.map { sys.now().addingTimeInterval($0) }
        apply()
    }

    func startManual(untilBattery p: Int) {
        manualUntilBattery = p
        manualDuration = nil
        startManual()
    }

    func stopManual() {
        manualActive = false
        manualUntil = nil
        authBlocked = false
        apply()
    }

    func retryAuth() {
        authBlocked = false
        apply()
    }

    /// `limit`: nil = use the default for new items; `.some(nil)` = unlimited.
    private func add(_ kind: TargetKind, limit: TimeInterval?? = nil, action: ExpireAction? = nil) {
        if targets.contains(where: { $0.kind == kind }) { return }
        targets.append(Target(kind: kind, limit: limit ?? defaultLimit, startedAt: sys.now(), action: action ?? defaultAction))
        batteryTripped = false
        authBlocked = false
    }

    func addProc(_ p: ProcInfo, name: String? = nil) {
        if let app = sys.apps().first(where: { $0.pid == p.pid && $0.regular }), let b = app.bundleID {
            add(.app(bundleID: b, name: app.name.isEmpty ? b : app.name))
        } else {
            add(.pid(p.pid, name: name ?? p.displayName, start: p.start.timeIntervalSince1970))
        }
    }

    /// Returns an error message, or nil on success.
    func addPID(_ text: String) -> String? {
        guard let pid = Int32(text.trimmingCharacters(in: .whitespaces)) else { return "Enter a number." }
        guard let p = procByPID[pid] else { return "No process with PID \(pid)." }
        addProc(p)
        return nil
    }

    func addName(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        add(.processName(n))
    }

    func addAgent(_ a: DetectedAgent, byName: Bool) {
        if byName { add(.processName(a.proc.displayName)) }
        else { addProc(a.proc, name: "\(a.agent) (\(a.proc.displayName))") }
    }

    /// Stop keeping a detected agent running (removes whichever kept item covers it).
    func unmark(_ a: DetectedAgent) {
        for t in targets where livePIDs(t).contains(a.proc.pid) { removeTarget(t.id) }
    }

    func addApp(bundleID: String, name: String) { add(.app(bundleID: bundleID, name: name)) }

    func chooseApp(_ handler: @escaping (String, String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let b = Bundle(url: url)?.bundleIdentifier else { continue }
            handler(b, url.deletingPathExtension().lastPathComponent)
        }
    }

    func removeTarget(_ id: UUID) {
        if let t = targets.first(where: { $0.id == id }) { unpauseTarget(t) }
        targets.removeAll { $0.id == id }
    }

    private func unpauseTarget(_ t: Target) {
        t.pausedPIDs.forEach { sys.signal($0, SIGCONT) }
        if t.containerPaused == true, let c = liveContainer(t) { _ = sys.dockerUnpause(c.id) }
    }

    func clearExited() {
        targets.removeAll { t in
            switch t.kind {
            case .pid: return livePIDs(t).isEmpty
            case .container: return liveContainer(t) == nil
            default: return false
            }
        }
    }

    func restartTarget(_ id: UUID) {
        guard let i = targets.firstIndex(where: { $0.id == id }) else { return }
        unpauseTarget(targets[i])
        targets[i].pausedPIDs = []
        targets[i].containerPaused = nil
        targets[i].expired = false
        targets[i].startedAt = sys.now()
        activity[id] = nil
        idleNotified.remove(id)
        batteryTripped = false
    }

    func resumeTarget(_ id: UUID) {
        guard let i = targets.firstIndex(where: { $0.id == id }) else { return }
        unpauseTarget(targets[i])
        targets[i].pausedPIDs = []
        targets[i].containerPaused = nil
    }

    var runningApps: [(name: String, bundleID: String)] {
        sys.apps()
            .filter { $0.regular && $0.bundleID != nil && $0.pid != getpid() }
            .map { ($0.name.isEmpty ? $0.bundleID! : $0.name, $0.bundleID!) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    func togglePasswordless() {
        if Power.passwordlessFileExists && passwordless {
            if Power.removePasswordless() { showAlert("Passwordless mode removed", "You'll be asked for your password again.") }
        } else if Power.installPasswordless() {
            showAlert("Passwordless mode on", "AlwaysUp can now switch sleep and Low Power Mode automatically — even with the lid closed. Only these exact pmset commands are allowed:\n\n• pmset -a disablesleep 0/1\n• pmset -b lowpowermode 0/1")
        }
        passwordless = sys.passwordlessReady()
        authBlocked = false
        apply()
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { showAlert("Couldn't change Launch at Login", "Move AlwaysUp.app into /Applications (./build.sh --install) and try again.\n\n\(error.localizedDescription)") }
            objectWillChange.send()
        }
    }

    // MARK: Text for the UI

    var reasonText: String {
        var parts: [String] = []
        if waitingForCharger { return "Waiting for the charger — plug in to stay awake." }
        if manualActive {
            if let p = manualUntilBattery { parts.append("until battery is \(p)%") }
            else { parts.append(manualUntil.map { "manual timer (\(formatDuration($0.timeIntervalSince(now))) left)" } ?? "manual (no limit)") }
        }
        if awakeForTargets, holdingCount > 0 { parts.append("\(holdingCount) kept item\(holdingCount == 1 ? "" : "s") running") }
        if batteryTripped { return "Stopped: battery below \(batteryThreshold)%. Plug in to resume." }
        if thermalTripped { return "Stopped: your Mac got too hot with the lid closed." }
        if authBlocked { return "Admin permission was cancelled." }
        return parts.isEmpty ? "Nothing is keeping the Mac awake." : "Awake because: " + parts.joined(separator: " + ")
    }

    func statusText(_ t: Target) -> String {
        if t.isTimerPaused { return "Paused (time's up)" }
        if case .container = t.kind {
            guard let c = liveContainer(t) else { return "Not running" }
            if !c.isRunning { return "Paused in Docker" }
            return t.expired ? "Time's up — not holding awake" : "Running · \(c.status)"
        }
        let pids = livePIDs(t)
        if pids.isEmpty { if case .pid = t.kind { return "Exited" }; return "Not running" }
        if t.expired { return "Time's up — not holding awake" }
        if isIdle(t) { return activity[t.id]?.done == true ? "Waiting for you — not holding awake" : "Idle — not holding awake" }
        let pidText = pids.count == 1 ? "PID \(pids[0])" : "\(pids.count) processes"
        return "Running · \(pidText)"
    }

    func limitText(_ t: Target) -> String {
        guard let l = t.limit else { return "Unlimited" }
        if t.expired { return "Expired" }
        return formatDuration(t.startedAt.addingTimeInterval(l).timeIntervalSince(now)) + " left"
    }

    // MARK: Notifications

    /// Self-test runs set ALWAYSUP_QUIET=1 so no notifications pop up.
    static let quiet = ProcessInfo.processInfo.environment["ALWAYSUP_QUIET"] == "1"
    private(set) var notifications: [String] = []

    /// `push`: also send it to the phone when the lid is closed (nobody can see the screen).
    func notify(_ title: String, _ body: String, push: Bool = true) {
        notifications.append(title)
        awaySession?.events.append(title)
        if push, lidClosed, Push.isValid(pushURL) {
            sys.push(pushURL, title, body)
            pushHold = sys.now().addingTimeInterval(4)
            if sys.live {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.3) { [weak self] in self?.tickAsync() }
            }
        }
        if Self.quiet || !sys.live { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func testPush() {
        guard Push.isValid(pushURL) else { return }
        sys.push(pushURL, "AlwaysUp test", "Phone notifications are working.")
    }

    // MARK: Quit

    /// `interactive: false` (killed by a signal / logout) never shows a password prompt.
    func shutdown(interactive: Bool = true) {
        watchdog?.terminate()       // a clean exit — nothing for it to do
        watchdog = nil
        exitSaver()
        for t in targets { unpauseTarget(t) }
        if awake { _ = sys.setSleepDisabled(false, interactive) }
        stopCaffeinate()
        for f in [restoreFile, sessionFile, pausedPIDsFile] { try? FileManager.default.removeItem(at: f) }
    }
}
