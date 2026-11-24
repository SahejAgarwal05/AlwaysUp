// SelfTest.swift — end-to-end tests that drive the real Engine.
// Built and run by Tests/run_tests.sh. Never touches Wi-Fi, Bluetooth or the screen.
// Only pauses the test's own dummy app (every other app is put on the never-pause list).

import AppKit

var passed = 0, failed = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("  ✅ \(name)") }
    else { failed += 1; print("  ❌ \(name)\(detail().isEmpty ? "" : " — \(detail())")") }
}
func section(_ s: String) { print("\n▸ \(s)") }
func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
func sh(_ cmd: String) -> String { Power.run("/bin/sh", ["-c", cmd]).output.trimmingCharacters(in: .whitespacesAndNewlines) }
func stat(_ pid: Int32) -> String { sh("ps -o stat= -p \(pid)") }
func stopped(_ pid: Int32) -> Bool { stat(pid).hasPrefix("T") }
func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }
func spawnSleep() -> Process {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = ["600"]; try! p.run(); return p
}

let env = ProcessInfo.processInfo.environment
let dummyApp = env["DUMMY_APP"]!
let dummyBundle = "local.alwaysup.dummy"

func launchDummy(child: Bool) -> NSRunningApplication? {
    let before = Set(NSRunningApplication.runningApplications(withBundleIdentifier: dummyBundle).map(\.processIdentifier))
    _ = sh("open -g -n '\(dummyApp)'" + (child ? " --args child" : ""))
    for _ in 0..<50 {
        wait(0.1)
        if let a = NSRunningApplication.runningApplications(withBundleIdentifier: dummyBundle)
            .first(where: { !before.contains($0.processIdentifier) }) { return a }
    }
    return nil
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.accessory)

    // ── 1. Settings from an older version still load (written before the engine starts).
    let oldJSON = """
    {"targets":[],"trigger":"always","saver":{"pauseApps":false,"displayOff":true,"bluetoothOff":false,"wifiOff":false,"lowPowerOnBattery":true},
     "awakeForTargets":true,"batteryGuard":true,"batteryThreshold":35,"neverPause":["com.example.x"],"defaultAction":"pause"}
    """
    UserDefaults.standard.set(Data(oldJSON.utf8), forKey: "state")

    let lowPowerBefore = Power.batteryLowPower()
    let sleepBefore = Power.isSleepDisabled()
    let e = Engine.shared

    section("Settings from an older version")
    check(e.trigger == .always, "trigger kept")
    check(e.batteryThreshold == 35, "battery threshold kept")
    check(e.defaultAction == .pause, "default action kept")
    check(e.saver.pauseApps == false && e.saver.displayOff, "saver options kept")
    check(e.saver.muteSpeakers == false && e.onlyWhileCharging == false, "new options get defaults")

    // Safe settings for the rest of the run.
    e.saver = SaverOptions(pauseApps: true, displayOff: false, bluetoothOff: false, wifiOff: false,
                           lowPowerOnBattery: true, muteSpeakers: true, muteHeadphones: false)
    e.trigger = .off
    e.batteryOverride = Battery(onBattery: false, percent: 80)
    e.lidOverride = false
    e.externalDisplayOverride = false
    e.defaultLimit = nil
    e.defaultAction = .release
    e.batteryGuard = true
    e.batteryThreshold = 20
    e.stopManual()
    e.tick()

    section("Basics")
    check(formatDuration(0) == "0s" && formatDuration(60) == "1m" && formatDuration(5400) == "1h 30m" && formatDuration(7200) == "2h",
          "duration text")
    let me = Proc.all().first { $0.pid == getpid() }
    check(me != nil && me!.ppid == getppid(), "process list finds itself with the right parent")
    check(Proc.args(getpid()).first?.contains("selftest") ?? false, "reads command-line arguments")
    check(e.passwordless, "passwordless mode ready")
    check(!e.awake && !Power.isSleepDisabled(), "starts asleep-able (SleepDisabled 0)", "awake=\(e.awake)")

    section("Agent detection")
    func p(_ path: String, _ comm: String) -> ProcInfo { ProcInfo(pid: 1, ppid: 1, uid: 0, comm: comm, path: path, start: Date()) }
    check(Agents.match(p("/Users/x/.local/share/claude/versions/2.1.0", "2.1.0"), args: ["claude"])?.name == "Claude Code", "Claude Code (native)")
    check(Agents.match(p("/opt/homebrew/bin/node", "node"), args: ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"])?.name == "Claude Code", "Claude Code (npm)")
    check(Agents.match(p("/opt/homebrew/bin/node", "node"), args: ["node", "/opt/homebrew/bin/gemini"])?.name == "Gemini CLI", "Gemini CLI")
    check(Agents.match(p("/opt/homebrew/bin/codex", "codex"), args: ["codex"])?.name == "Codex CLI", "Codex CLI")
    check(Agents.match(p("/usr/bin/python3", "python3"), args: ["python3", "/usr/local/bin/aider"])?.name == "Aider", "Aider")
    check(Agents.match(p("/Applications/Claude.app/Contents/MacOS/Claude", "Claude"), args: [])?.isApp == true, "Claude desktop app")
    check(Agents.match(p("/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper", "Claude Helper"), args: []) == nil, "ignores app helpers")
    check(Agents.match(p("/Users/x/.local/bin/claude", "claude"), args: ["claude", "--chrome-native-host"]) == nil, "ignores browser bridge")
    check(Agents.match(p("/usr/bin/vim", "vim"), args: ["vim", "notes.txt"]) == nil, "ignores normal programs")

    section("Kept process keeps the Mac awake")
    let s1 = spawnSleep()
    e.tick()
    guard let info = e.procs.first(where: { $0.pid == s1.processIdentifier }) else { fatalError("no proc") }
    e.addProc(info)
    e.tick()
    check(e.holdingCount == 1, "process counts as running")
    check(e.awake && Power.isSleepDisabled(), "Mac kept awake (SleepDisabled 1)")
    check(!sh("pgrep -f 'caffeinate -ims -w \(getpid())'").isEmpty, "caffeinate running")
    s1.terminate(); s1.waitUntilExit()
    e.tick()
    check(e.holdingCount == 0, "process exit noticed")
    check(!e.awake && !Power.isSleepDisabled(), "Mac allowed to sleep again (SleepDisabled 0)")
    check(sh("pgrep -f 'caffeinate -ims -w \(getpid())'").isEmpty, "caffeinate stopped")
    e.clearExited()
    check(e.targets.isEmpty, "clear exited")

    section("Per-item timer: pause when time's up")
    let s2 = spawnSleep()
    e.tick()
    e.addProc(e.procs.first { $0.pid == s2.processIdentifier }!)
    e.targets[0].limit = 2
    e.targets[0].action = .pause
    e.tick()
    check(e.awake, "awake while timer runs")
    wait(2.5); e.tick()
    check(stopped(s2.processIdentifier), "process paused at time's up", stat(s2.processIdentifier))
    check(e.statusText(e.targets[0]).hasPrefix("Paused"), "status says paused")
    check(!e.awake, "no longer holds the Mac awake")
    e.resumeTarget(e.targets[0].id)
    check(!stopped(s2.processIdentifier), "Resume continues it")
    e.targets[0].limit = nil   // made unlimited → active again
    e.tick()
    check(!e.targets[0].expired && e.awake, "raising the limit re-activates it")
    e.removeTarget(e.targets[0].id); e.tick()
    s2.terminate()

    section("Per-item timer: quit when time's up")
    let s3 = spawnSleep()
    e.tick()
    e.addProc(e.procs.first { $0.pid == s3.processIdentifier }!)
    e.targets[0].limit = 2
    e.targets[0].action = .quit
    wait(2.5); e.tick()
    wait(0.3)
    check(!s3.isRunning, "process quit at time's up")
    e.targets.removeAll(); e.tick()

    section("Process-name items")
    e.addName("sleep")
    let s4 = spawnSleep()
    e.tick()
    check(e.isHolding(e.targets[0]), "matches a process by name")
    e.targets.removeAll(); s4.terminate(); e.tick()

    section("Manual keep-awake timer")
    e.startManual(.some(2))
    check(e.awake && e.manualActive, "on")
    wait(2.5); e.tick()
    check(!e.manualActive && !e.awake, "turns itself off when the time is up")

    section("Battery rules")
    e.batteryOverride = Battery(onBattery: true, percent: 50)
    e.startManual(untilBattery: 40)
    e.tick()
    check(e.awake, "until 40%: awake at 50%")
    e.batteryOverride = Battery(onBattery: true, percent: 40); e.tick()
    check(!e.manualActive && !e.awake, "until 40%: stops at 40%")

    e.onlyWhileCharging = true
    e.startManual(.some(nil)); e.tick()
    check(e.waitingForCharger && !e.awake, "only while plugged in: waits on battery")
    e.batteryOverride = Battery(onBattery: false, percent: 40); e.tick()
    check(!e.waitingForCharger && e.awake, "only while plugged in: awake once plugged in")
    e.batteryOverride = Battery(onBattery: true, percent: 40); e.tick()
    check(!e.awake, "only while plugged in: sleeps again when unplugged")
    e.stopManual(); e.onlyWhileCharging = false; wait(0.1)

    e.batteryOverride = Battery(onBattery: true, percent: 15)
    e.startManual(.some(nil)); e.tick()
    check(e.batteryTripped && !e.awake, "low battery safety net (below 20%)")
    e.batteryOverride = Battery(onBattery: false, percent: 15); e.tick()
    check(!e.batteryTripped, "safety net resets when plugged in")
    e.stopManual()
    e.batteryOverride = Battery(onBattery: true, percent: 80)
    e.tick()

    section("Saver Mode (lid closed)")
    guard let dummyA = launchDummy(child: false) else { fatalError("dummy app didn't launch") }
    let a = dummyA.processIdentifier
    // Protect every real app — only the dummy may be paused.
    e.neverPause = e.runningApps.map(\.bundleID).filter { $0 != dummyBundle }
    e.trigger = .lidClosed
    let speakers = Audio.builtInOutputs().filter { !$0.isHeadphones }
    let mutedBefore = speakers.map { Audio.isMuted($0.id) }
    e.startManual(.some(nil)); e.tick()
    check(e.awake && !e.saverActive, "lid open: Saver Mode stays off")
    e.lidOverride = true; e.tick()
    check(e.saverActive, "lid closed: Saver Mode on")
    check(stopped(a), "unmarked app paused", stat(a))
    let realApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != dummyBundle }
    check(realApps.allSatisfy { !stopped($0.processIdentifier) }, "your real apps untouched (never-pause list)")
    check(speakers.allSatisfy { Audio.isMuted($0.id) == true }, "speakers muted")
    check(Power.batteryLowPower() == 1, "Low Power Mode on battery switched on")
    check(FileManager.default.fileExists(atPath: env["ALWAYSUP_SUPPORT_DIR"]! + "/restore.json"), "restore info saved for crash recovery")

    section("Apps an agent runs inside are protected")
    guard let dummyB = launchDummy(child: true) else { fatalError("dummy B didn't launch") }
    let b = dummyB.processIdentifier
    wait(0.5); e.tick()
    check(stopped(b), "a second unmarked app is paused too")
    guard let childOfB = e.procs.first(where: { $0.ppid == b && $0.displayName == "sleep" }) else { fatalError("no child") }
    e.addProc(childOfB, name: "Pretend agent")
    e.tick()
    check(!stopped(b), "marking a process inside it un-pauses its parent app")
    check(!stopped(childOfB.pid), "the marked process keeps running")
    check(stopped(a), "the other app stays paused")

    section("External monitor counts as in use")
    e.externalDisplayOverride = true; e.tick()
    check(!e.saverActive && !stopped(a), "monitor connected: Saver Mode off, app resumed")
    e.externalDisplayOverride = false; e.tick()
    check(e.saverActive && stopped(a), "monitor removed: Saver Mode back on")

    section("Opening the lid restores everything")
    e.lidOverride = false; e.tick()
    check(!e.saverActive, "Saver Mode off")
    check(!stopped(a) && !stopped(b), "apps resumed")
    check(zip(speakers, mutedBefore).allSatisfy { Audio.isMuted($0.0.id) == $0.1 }, "speakers back to how they were")
    check(Power.batteryLowPower() == lowPowerBefore, "Low Power Mode back to how it was (\(lowPowerBefore.map(String.init) ?? "?"))")
    check(e.restore.pausedApps.isEmpty && e.restore.audioWasMuted.isEmpty && e.restore.lowPowerPrev == nil, "nothing left to restore")

    section("'Whenever awake' mode also restores on lid open")
    e.trigger = .always; e.tick()
    check(e.saverActive && stopped(a), "on while awake (lid open)")
    e.lidOverride = true; e.tick()
    e.lidOverride = false; e.tick()
    check(!e.saverActive && !stopped(a), "lid opened: restored")
    e.tick()
    check(!e.saverActive, "stays restored until next lid close")
    e.lidOverride = true; e.tick()
    check(e.saverActive, "next lid close: on again")
    e.lidOverride = false; e.tick()
    e.trigger = .lidClosed

    section("Never-pause list")
    e.neverPause.append(dummyBundle)
    e.lidOverride = true; e.tick()
    check(e.saverActive && !stopped(a), "app on the list is not paused")
    e.lidOverride = false; e.tick()
    e.neverPause.removeAll { $0 == dummyBundle }

    section("Resume All Now")
    e.lidOverride = true; e.tick()
    check(stopped(a), "paused")
    e.snoozeSaver()
    check(!stopped(a) && !e.saverActive, "Resume All resumes and pauses Saver Mode")
    e.tick()
    check(!stopped(a), "stays resumed while lid is still closed")
    e.lidOverride = false; e.tick()

    section("Crash recovery")
    kill(a, SIGSTOP)
    let fake = SaverRestore(pausedApps: [PausedApp(pid: a, name: "Dummy", bundleID: dummyBundle, pids: [a])])
    try! JSONEncoder().encode(fake).write(to: URL(fileURLWithPath: env["ALWAYSUP_SUPPORT_DIR"]! + "/restore.json"))
    e.recoverFromCrash()
    check(!stopped(a), "apps left paused by a crash are resumed on next launch")

    e.stopManual()
    e.targets.removeAll()
    e.tick()

    section("Docker containers (fake Docker server)")
    e.refreshContainers()
    check(e.dockerAvailable, "finds Docker via DOCKER_HOST", Docker.socketPath ?? "no socket")
    check(e.containers.map(\.name).sorted() == ["agent-box", "postgres"], "lists running containers", "\(e.containers.map(\.name))")
    let box = e.containers.first { $0.name == "agent-box" }!
    e.addContainer(box); e.tick()
    check(e.isMarked(box) && e.holdingCount == 1, "kept container counts as running")
    check(e.awake, "keeps the Mac awake")
    _ = Docker.request("POST", "/_test/recreate/agent-box", socket: Docker.socketPath!)
    e.tick()
    check(e.holdingCount == 1, "still tracked after `docker compose up` recreates it (new ID)")
    e.targets[0].limit = 2; e.targets[0].action = .pause
    wait(2.5); e.tick()
    check(e.containers.first { $0.name == "agent-box" }?.state == "paused", "time's up → container paused")
    check(e.statusText(e.targets[0]).hasPrefix("Paused") && !e.awake, "status paused, no longer holding awake")
    e.resumeTarget(e.targets[0].id); e.tick()
    check(e.containers.first { $0.name == "agent-box" }?.state == "running", "Resume unpauses the container")
    e.restartTarget(e.targets[0].id); e.targets[0].action = .quit; e.targets[0].limit = 2
    wait(2.5); e.tick(); e.tick()
    check(e.containers.first { $0.name == "agent-box" } == nil, "time's up → container stopped")
    check(!e.awake, "Mac can sleep once the container is gone")
    e.targets.removeAll(); e.tick()

    section("Quit restores everything")
    e.lidOverride = true
    e.startManual(.some(nil)); e.tick()
    check(e.saverActive && stopped(a), "set up: awake + Saver Mode + paused app")
    e.shutdown()
    check(!stopped(a), "paused app resumed")
    check(!Power.isSleepDisabled(), "sleep restored (SleepDisabled 0)")
    check(Power.batteryLowPower() == lowPowerBefore, "Low Power Mode restored")
    check(zip(speakers, mutedBefore).allSatisfy { Audio.isMuted($0.0.id) == $0.1 }, "speakers restored",
          "before=\(mutedBefore) now=\(speakers.map { Audio.isMuted($0.id) }) left=\(e.restore.audioWasMuted)")

    // Clean up
    dummyA.forceTerminate(); dummyB.forceTerminate()
    _ = sh("pkill -f 'sleep 900'")
    if sleepBefore { _ = Power.setSleepDisabled(true, prompt: false) }

    print("\n\(failed == 0 ? "✅" : "❌") \(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}
