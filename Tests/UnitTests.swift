// UnitTests.swift — fast tests of the Engine's rules against a fake Mac.
// Built and run by Tests/run_unit_tests.sh. Needs no admin rights and touches nothing real:
// no pmset, no signals, no radios, no audio, no network.

import AppKit

var passed = 0, failed = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("  ✅ \(name)") }
    else { failed += 1; print("  ❌ \(name)\(detail().isEmpty ? "" : " — \(detail())")") }
}
func section(_ s: String) { print("\n▸ \(s)") }

/// A pretend Mac. Tests change its fields, then call `engine.tick()`.
final class World {
    var time = Date(timeIntervalSince1970: 1_700_000_000)
    var procs: [ProcInfo] = []
    var apps: [AppInfo] = []
    var lid = false, display = false
    var battery: Battery? = Battery(onBattery: false, percent: 80)
    var containers: [Container]?
    var thermal: ProcessInfo.ThermalState = .nominal
    var sleepDisabled = false
    var lowPower = 0
    var signals: [String] = []
    var cpu: [Int32: Double] = [:]
    var responsible: [Int32: Int32] = [:]
    var args: [Int32: [String]] = [:]
    var argReads = 0
    var sleepNow = 0
    var pushes: [String] = []
    var dockerPolls: [Bool] = []
    var dockerCalls: [String] = []

    func add(_ pid: Int32, ppid: Int32 = 1, _ name: String, path: String? = nil) {
        procs.append(ProcInfo(pid: pid, ppid: ppid, uid: getuid(), comm: name, path: path ?? "/usr/bin/\(name)",
                              start: Date(timeIntervalSince1970: 1_600_000_000 + Double(pid))))
    }
    func remove(_ pid: Int32) { procs.removeAll { $0.pid == pid } }
    func app(_ pid: Int32, _ name: String, _ bundleID: String) {
        add(pid, name, path: "/Applications/\(name).app/Contents/MacOS/\(name)")
        apps.append(AppInfo(pid: pid, bundleID: bundleID, name: name, regular: true, bundlePath: "/Applications/\(name).app"))
    }
    func advance(_ s: TimeInterval) { time += s }
    func sent(_ sig: String, _ pid: Int32) -> Bool { signals.contains("\(sig) \(pid)") }

    var system: System {
        var s = System()
        s.live = false
        s.now = { self.time }
        s.snapshot = { docker in
            self.dockerPolls.append(docker)
            return Snapshot(procs: self.procs, lidClosed: self.lid, externalDisplay: self.display, battery: self.battery,
                            containers: docker ? self.containers : nil, dockerPolled: docker, thermal: self.thermal)
        }
        s.procs = { self.procs }
        s.apps = { self.apps }
        s.args = { self.argReads += 1; return self.args[$0] ?? [] }
        s.cpuTime = { self.cpu[$0] ?? 0 }
        s.responsible = { self.responsible[$0] }
        s.signal = { pid, sig in
            self.signals.append("\(sig == SIGSTOP ? "STOP" : sig == SIGCONT ? "CONT" : sig == SIGTERM ? "TERM" : "\(sig)") \(pid)")
        }
        s.terminateApp = { self.signals.append("QUIT \($0)") }
        s.setSleepDisabled = { on, _ in self.sleepDisabled = on; return true }
        s.isSleepDisabled = { self.sleepDisabled }
        s.passwordlessReady = { true }
        s.batteryLowPower = { self.lowPower }
        s.setBatteryLowPower = { self.lowPower = $0; return true }
        s.displaySleepNow = {}
        s.sleepNow = { self.sleepNow += 1 }
        s.bluetoothAvailable = { false }
        s.bluetoothOn = { false }
        s.setBluetooth = { _ in }
        s.wifiAvailable = { false }
        s.wifiOn = { false }
        s.setWiFi = { _ in }
        s.audioOutputs = { [] }
        s.isMuted = { _ in nil }
        s.setMuted = { _, _ in }
        s.dockerList = { self.containers }
        s.dockerPause = { self.dockerCalls.append("pause \($0)"); return true }
        s.dockerUnpause = { self.dockerCalls.append("unpause \($0)"); return true }
        s.dockerStop = { self.dockerCalls.append("stop \($0)"); return true }
        s.push = { _, title, _ in self.pushes.append(title) }
        return s
    }
}

let suite = "local.alwaysup.unittest"
let tmpRoot = FileManager.default.temporaryDirectory.appendingPathComponent("alwaysup-unit-\(getpid())", isDirectory: true)
var engineCount = 0

func freshDir() -> URL {
    engineCount += 1
    let d = tmpRoot.appendingPathComponent("\(engineCount)", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@MainActor
func makeEngine(_ w: World, dir: URL? = nil, state: String? = nil) -> Engine {
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    if let s = state { d.set(Data(s.utf8), forKey: "state") }
    return Engine(system: w.system, defaults: d, supportDir: dir ?? freshDir())
}

func request(_ dir: URL, _ r: Request) {
    let rd = Paths.requests(in: dir)
    try? FileManager.default.createDirectory(at: rd, withIntermediateDirectories: true)
    try! JSONEncoder().encode(r).write(to: rd.appendingPathComponent("\(UUID().uuidString).json"))
}

MainActor.assumeIsolated {
    section("Kept process")
    do {
        let w = World(); w.add(100, "sleep")
        let e = makeEngine(w)
        e.addProc(e.procs[0]); e.tick()
        check(e.awake && w.sleepDisabled, "keeps the Mac awake while it runs")
        w.remove(100); e.tick()
        check(!e.awake && !w.sleepDisabled, "lets it sleep when the process exits")
        check(e.notifications.contains("sleep finished"), "says it finished", "\(e.notifications)")
        check(w.sleepNow == 0, "lid open: doesn't force sleep")
    }

    section("Settings from an older version")
    do {
        let e = makeEngine(World(), state: #"{"targets":[],"trigger":"always","batteryThreshold":35}"#)
        check(e.trigger == .always && e.batteryThreshold == 35, "old values kept")
        check(e.thermalGuard && e.idleRelease == nil && e.pushURL.isEmpty && e.customAgents.isEmpty, "new options get defaults")
    }

    section("Releasing with the lid closed puts the Mac to sleep")
    do {
        let w = World(); let e = makeEngine(w)
        e.trigger = .off
        e.startManual(.some(60))
        w.lid = true; e.tick()
        check(e.awake, "awake with the lid closed")
        w.advance(61); e.tick()
        check(!e.awake && w.sleepNow == 1, "timer ends while away → sleep now", "sleepNow=\(w.sleepNow)")
        w.lid = false; e.tick()
        e.startManual(.some(60)); w.advance(61); e.tick()
        check(!e.awake && w.sleepNow == 1, "timer ends at your desk → no forced sleep")
        w.lid = true; w.display = true
        e.startManual(.some(60)); e.tick(); w.advance(61); e.tick()
        check(!e.awake && w.sleepNow == 1, "lid closed but using a monitor → no forced sleep")
    }

    section("Overheating guard")
    do {
        let w = World(); let e = makeEngine(w)
        e.trigger = .off
        e.startManual(.some(nil)); w.lid = true; e.tick()
        w.thermal = .fair; e.tick()
        check(e.awake && !e.thermalTripped, "warm is fine")
        w.thermal = .serious; e.tick()
        check(e.thermalTripped && !e.awake && w.sleepNow == 1, "hot with the lid closed → let it sleep")
        check(e.reasonText.contains("too hot"), "says why")
        w.lid = false; e.tick()
        check(!e.thermalTripped && e.awake, "opening the lid resumes")
        e.thermalGuard = false; w.lid = true; e.tick()
        check(e.awake && !e.thermalTripped, "guard switched off → stays awake")
        e.thermalGuard = true; w.lid = false; w.thermal = .critical; e.tick()
        check(e.awake && !e.thermalTripped, "hot at your desk (lid open) is left alone")
    }

    section("Time limit counts from when the item starts running")
    do {
        let w = World(); let e = makeEngine(w)
        e.addName("node"); e.targets[0].limit = 100
        e.tick(); w.advance(500); e.tick()
        check(!e.awake, "not running → not awake")
        w.add(50, "node"); e.tick()
        check(e.isHolding(e.targets[0]) && e.awake, "starts later → gets its full time", e.statusText(e.targets[0]))
        w.advance(60); e.tick()
        check(e.awake, "still inside the limit")
        w.advance(60); e.tick()
        check(e.targets[0].expired && !e.awake, "expires 100s after it started")
        w.remove(50); e.tick(); w.add(51, "node"); e.tick()
        check(!e.targets[0].expired && e.awake, "next run gets a fresh timer")
    }

    section("Time's up: pause")
    do {
        let w = World(); w.add(100, "agent"); w.add(101, ppid: 100, "child")
        let e = makeEngine(w)
        e.addProc(e.procs[0]); e.targets[0].limit = 10; e.targets[0].action = .pause
        e.tick(); w.advance(11); e.tick()
        check(w.sent("STOP", 100) && w.sent("STOP", 101), "pauses the process and its children")
        check(!e.awake, "no longer holds the Mac awake")
        e.resumeTarget(e.targets[0].id)
        check(w.sent("CONT", 100) && w.sent("CONT", 101), "Resume continues them")
    }

    section("Idle detection")
    do {
        let w = World(); w.add(100, "agent"); w.add(101, ppid: 100, "tool")
        w.cpu = [100: 10, 101: 1]
        let dir = freshDir()
        let e = makeEngine(w, dir: dir)
        e.idleRelease = 300
        e.addProc(e.procs[0]); e.tick()
        for _ in 0..<20 { w.advance(10); w.cpu[100]! += 1; e.tick() }
        check(e.awake, "busy agent keeps the Mac awake")
        for _ in 0..<29 { w.advance(10); w.cpu[100]! += 0.01; e.tick() }
        check(e.awake, "quiet for under 5 minutes → still awake")
        for _ in 0..<3 { w.advance(10); e.tick() }
        check(!e.awake && e.statusText(e.targets[0]).hasPrefix("Idle"), "idle for 5 minutes → released", e.statusText(e.targets[0]))
        w.advance(10); w.cpu[101]! += 2; e.tick()
        check(e.awake, "work in a child process counts → awake again")

        e.idleRelease = nil
        request(dir, Request(cmd: "done", pids: [999, 100])); e.tick()
        check(!e.awake && e.statusText(e.targets[0]).hasPrefix("Waiting"), "`AlwaysUp done` releases at once", e.statusText(e.targets[0]))
        w.advance(10); e.tick()
        check(!e.awake, "stays released while it does nothing")
        w.advance(10); w.cpu[100]! += 3; e.tick()
        check(e.awake, "holds again when it gets busy")
        request(dir, Request(cmd: "done", pids: [100])); e.tick()
        request(dir, Request(cmd: "busy", pids: [100])); e.tick()
        check(e.awake, "`AlwaysUp busy` holds again")
        check((try? FileManager.default.contentsOfDirectory(atPath: Paths.requests(in: dir).path))?.isEmpty ?? false, "request files are cleaned up")

        request(dir, Request(cmd: "simulate", pids: [], sim: ["lid": "closed", "battery": "15"])); e.tick(); e.tick()
        check(e.lidClosed && e.battery == Battery(onBattery: true, percent: 15) && e.simulating == "lid closed, battery 15%",
              "`AlwaysUp simulate` fakes the lid and battery", e.simulating)
        request(dir, Request(cmd: "simulate", pids: [], sim: [:])); e.tick(); e.tick()
        check(!e.lidClosed && e.simulating.isEmpty, "`simulate off` goes back to the real readings")
    }

    section("`AlwaysUp run` request")
    do {
        let w = World(); w.add(100, "make")
        let dir = freshDir()
        let e = makeEngine(w, dir: dir)
        request(dir, Request(cmd: "keep", pids: [100], name: "make", limit: 120, action: .quit)); e.tick()
        check(e.targets.count == 1 && e.targets.first?.limit == 120 && e.targets.first?.action == .quit, "adds the process with its limit")
        check(e.awake, "and keeps the Mac awake for it")
        check(CLI.parseDuration("45m") == 2700 && CLI.parseDuration("1h30m") == 5400 && CLI.parseDuration("90") == 5400 &&
              CLI.parseDuration("soon") == nil, "reads times like 45m, 1h30m")
    }

    section("Saver Mode pauses apps and their helpers")
    do {
        let w = World()
        w.app(10, "Terminal", "com.apple.Terminal"); w.add(11, ppid: 10, "zsh"); w.add(100, ppid: 11, "agent")
        w.app(20, "Browser", "com.example.browser"); w.add(21, ppid: 20, "Browser Helper")
        w.add(22, "WebContent", path: "/System/Library/Frameworks/WebKit.framework/XPCServices/WebContent.xpc/Contents/MacOS/WebContent")
        w.add(23, "Share", path: "/Applications/Browser.app/Contents/PlugIns/Share.appex/Contents/MacOS/Share")
        w.add(24, "Other", path: "/System/Library/Other.xpc/Contents/MacOS/Other")
        w.app(30, "Finder", "com.apple.finder")
        w.responsible = [22: 20, 23: 20, 24: 999]
        let e = makeEngine(w)
        e.addProc(e.procs.first { $0.pid == 100 }!); e.tick()
        check(e.awake && !e.saverActive, "lid open: nothing paused")
        w.lid = true; e.tick()
        check(e.saverActive && w.sent("STOP", 20) && w.sent("STOP", 21), "pauses the other app and its children")
        check(w.sent("STOP", 22), "pauses its XPC helper (not a child process)")
        check(!w.sent("STOP", 23) && !w.sent("STOP", 24), "leaves app extensions and other apps' helpers alone")
        check(!w.sent("STOP", 10) && !w.sent("STOP", 11) && !w.sent("STOP", 100) && !w.sent("STOP", 30),
              "never pauses the agent, its terminal, or Finder")
        check(w.lowPower == 1, "Low Power Mode on")
        w.lid = false; e.tick()
        check(w.sent("CONT", 20) && w.sent("CONT", 21) && w.sent("CONT", 22) && w.lowPower == 0, "lid open: everything restored")
    }

    section("Docker isn't polled while its runtime is paused")
    do {
        let w = World(); w.containers = []
        w.app(40, "Docker", "com.docker.docker")
        let e = makeEngine(w)
        e.startManual(.some(nil)); w.lid = true; e.tick()
        check(w.sent("STOP", 40), "Saver Mode paused Docker Desktop")
        e.tick()
        check(w.dockerPolls.last == false, "socket left alone while it's frozen")
        w.lid = false; e.tick(); e.tick()
        check(w.dockerPolls.last == true, "polled again once resumed")

        let w2 = World(); w2.app(40, "Docker", "com.docker.docker")
        w2.containers = [Container(id: "abc", name: "box", image: "img", state: "running", status: "Up")]
        let e2 = makeEngine(w2)
        e2.addContainer(e2.containers[0]); w2.lid = true; e2.tick()
        check(e2.awake && !w2.sent("STOP", 40), "a kept container protects the runtime")
        w2.containers = []; e2.tick()
        check(!e2.awake && e2.notifications.contains("box finished"), "container gone → released and reported")
    }

    section("Agent detection")
    do {
        func p(_ path: String) -> ProcInfo { ProcInfo(pid: 1, ppid: 1, uid: 0, comm: (path as NSString).lastPathComponent, path: path, start: Date()) }
        check(Agents.match(p("/usr/bin/less"), args: ["less", "claude"]) == nil, "`less claude` is not Claude")
        check(Agents.match(p("/bin/cat"), args: ["cat", "codex"]) == nil, "`cat codex` is not Codex")
        check(Agents.match(p("/opt/homebrew/bin/node"), args: ["node", "/opt/homebrew/bin/gemini"])?.name == "Gemini CLI", "node running a script still matches")
        check(Agents.match(p("/usr/bin/python3.12"), args: ["python3.12", "/usr/local/bin/aider"])?.name == "Aider", "python running a script still matches")
        check(Agents.match(p("/Users/x/.local/share/claude/versions/2.1.0"), args: ["claude"])?.name == "Claude Code", "native Claude Code still matches")
        check(Agents.match(p("/usr/local/bin/devin"), args: ["devin"]) == nil, "unknown program ignored")
        check(Agents.match(p("/usr/local/bin/devin"), args: ["devin"], custom: ["Devin"])?.name == "Devin", "custom agent name matches")

        let w = World(); w.add(100, "claude"); w.add(101, "vim"); w.args = [100: ["claude"], 101: ["vim"]]
        let e = makeEngine(w)
        e.scanAgents()
        let reads = w.argReads
        e.scanAgents(); e.tick(); e.scanAgents()
        check(e.detected.map(\.agent) == ["Claude Code"], "finds the agent")
        check(w.argReads == reads, "command lines are read once, then remembered", "\(reads) → \(w.argReads)")
        e.customAgents = ["vim"]; e.scanAgents()
        check(e.detected.count == 2, "adding a custom name re-scans")
    }

    section("Relaunch after a crash")
    do {
        let w = World(); w.sleepDisabled = true
        let dir = freshDir()
        let until = w.time.addingTimeInterval(600).timeIntervalSinceReferenceDate
        try! Data(#"{"manualActive":true,"manualUntil":\#(until)}"#.utf8).write(to: dir.appendingPathComponent("session.json"))
        let e = makeEngine(w, dir: dir)
        check(e.awake && e.manualActive && e.manualUntil != nil, "picks up the same timed session (not an unlimited one)")
        w.advance(601); e.tick()
        check(!e.awake && !w.sleepDisabled, "and still ends it on time")

        let w2 = World(); w2.sleepDisabled = true
        let dir2 = freshDir()
        try! Data(#"{"manualActive":false}"#.utf8).write(to: dir2.appendingPathComponent("session.json"))
        let e2 = makeEngine(w2, dir: dir2)
        check(!e2.awake && !w2.sleepDisabled, "was only awake for an item that's gone → sleep re-enabled")
    }

    section("While you were away")
    do {
        let w = World(); w.battery = Battery(onBattery: true, percent: 80)
        let e = makeEngine(w)
        e.trigger = .off
        e.startManual(.some(nil)); w.lid = true; e.tick()
        for i in 1...30 { w.advance(10); w.battery = Battery(onBattery: true, percent: 80 - i / 3); e.tick() }
        check(e.lastAway == nil, "nothing shown while still away")
        w.lid = false; e.tick()
        let a = e.lastAway
        check(a != nil && abs((a?.awake ?? 0) - 300) < 1 && a?.batteryFrom == 80 && a?.batteryTo == 70, "summary on lid open", a?.text ?? "none")
        e.dismissAway()
        check(e.lastAway == nil, "can be dismissed")
    }

    section("Phone notifications")
    do {
        let w = World(); w.add(100, "agent")
        let e = makeEngine(w)
        e.trigger = .off
        e.pushURL = "https://ntfy.sh/example"
        e.addProc(e.procs[0]); e.tick()
        w.lid = true; e.tick()
        w.remove(100); e.tick()
        check(w.pushes == ["agent finished"], "sent when the lid is closed", "\(w.pushes)")
        check(e.awake && w.sleepNow == 0, "stays awake a moment so the message gets out")
        w.advance(5); e.tick()
        check(!e.awake && w.sleepNow == 1, "then sleeps")
        w.lid = false; e.tick(); w.pushes = []
        w.add(101, "agent"); e.tick(); e.addProc(e.procs[0]); e.tick(); w.remove(101); e.tick()
        check(w.pushes.isEmpty, "not sent while you're at the Mac")
        check(!Push.isValid("ftp://x") && !Push.isValid("hello") && Push.isValid("https://ntfy.sh/t"), "only http(s) addresses accepted")
    }

    section("Battery rules")
    do {
        let w = World(); w.battery = Battery(onBattery: true, percent: 15)
        let e = makeEngine(w)
        e.startManual(.some(nil)); e.tick()
        check(e.batteryTripped && !e.awake, "low battery safety net")
        w.battery = Battery(onBattery: false, percent: 15); e.tick()
        check(!e.batteryTripped, "resets when plugged in")
        e.onlyWhileCharging = true; e.startManual(.some(nil)); e.tick()
        check(e.awake, "only while plugged in: awake on power")
        w.battery = Battery(onBattery: true, percent: 90); e.tick()
        check(!e.awake && e.waitingForCharger, "only while plugged in: waits on battery")
    }

    try? FileManager.default.removeItem(at: tmpRoot)
    UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    print("\n\(failed == 0 ? "✅" : "❌") \(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}
