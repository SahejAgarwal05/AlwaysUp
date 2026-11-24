// main.swift — menu bar item, window, app lifecycle.

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var signalSources: [DispatchSourceSignal] = []
    private var e: Engine { Engine.shared }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Make sure paused apps / radios / sleep are restored if we're killed.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                MainActor.assumeIsolated { Engine.shared.shutdown(interactive: false) }
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }

        e.onUpdate = { [weak self] in self?.updateIcon() }
        updateIcon()
        if !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            openWindow()
        }
    }

    func applicationWillTerminate(_ note: Notification) { e.shutdown() }

    private func updateIcon() {
        statusItem.button?.image = Logo.menuBar(!e.awake ? .off : (e.saverActive ? .saver : .awake))
        statusItem.button?.toolTip = "AlwaysUp — " + e.reasonText
    }

    // MARK: Window

    @objc func openWindow() {
        if window == nil {
            let size = MainView.size(advanced: UserDefaults.standard.bool(forKey: "advancedUI"))
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "AlwaysUp"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: MainView(e: e))
            w.delegate = self
            w.center()
            window = w
        }
        e.windowVisible = true
        e.refreshForMenu()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        e.windowVisible = false
        // Let go of the window so SwiftUI isn't redrawing a hidden view on every tick.
        DispatchQueue.main.async { [weak self] in
            if self?.window?.isVisible == false { self?.window = nil }
        }
    }

    // MARK: Menu (rebuilt each time it opens)

    func menuNeedsUpdate(_ m: NSMenu) {
        e.refreshForMenu()
        m.removeAllItems()

        m.addItem(disabled(e.awake ? "● Awake — lid can be closed" : "○ Off — Mac sleeps normally"))
        m.addItem(disabled(e.reasonText))
        if e.saverActive { m.addItem(disabled("Saver Mode on · \(e.restore.pausedApps.count) app(s) paused")) }
        if let b = e.battery { m.addItem(disabled("Battery \(b.percent)% · \(b.onBattery ? "on battery" : "plugged in")")) }
        m.addItem(.separator())

        m.addItem(item("Open AlwaysUp…", #selector(openWindow), key: ","))
        m.addItem(.separator())

        if e.manualActive {
            let left = e.manualUntil.map { " (\(formatDuration($0.timeIntervalSince(Date()))) left)" } ?? ""
            m.addItem(item("Stop Keeping Awake" + left, #selector(stopManual), key: "o"))
        } else {
            m.addItem(item("Keep Awake — No Limit", #selector(startUnlimited), key: "a"))
            if let p = e.manualUntilBattery {
                m.addItem(item("Keep Awake Until Battery Is \(p)%", #selector(startDefault)))
            } else if let d = e.manualDuration {
                m.addItem(item("Keep Awake for \(formatDuration(d))", #selector(startDefault)))
            }
        }
        let forItem = NSMenuItem(title: "Keep Awake For…", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (label, secs) in Durations.presets {
            let i = item(label, #selector(startFor(_:)))
            i.representedObject = secs
            sub.addItem(i)
        }
        sub.addItem(.separator())
        for p in StatusCard.batteryStops {
            let i = item("Until battery is \(p)%", #selector(startUntilBattery(_:)))
            i.representedObject = p
            sub.addItem(i)
        }
        sub.addItem(.separator())
        sub.addItem(item("Custom…", #selector(openWindow)))
        forItem.submenu = sub
        m.addItem(forItem)
        let charge = item("Only While Plugged In", #selector(toggleCharging))
        charge.state = e.onlyWhileCharging ? .on : .off
        m.addItem(charge)

        // Kept items
        m.addItem(.separator())
        m.addItem(disabled("Kept running"))
        if e.targets.isEmpty { m.addItem(disabled("   none — mark agents below or in the window")) }
        for t in e.targets {
            let ti = NSMenuItem(title: "   \(t.displayName) — \(e.statusText(t)) · \(e.limitText(t))", action: nil, keyEquivalent: "")
            let ts = NSMenu()
            let r = item("Restart Timer", #selector(restartTarget(_:))); r.representedObject = t.id; ts.addItem(r)
            if t.isTimerPaused { let p = item("Resume", #selector(resumeTarget(_:))); p.representedObject = t.id; ts.addItem(p) }
            let x = item("Remove", #selector(removeTarget(_:))); x.representedObject = t.id; ts.addItem(x)
            ti.submenu = ts
            m.addItem(ti)
        }

        // Docker containers
        let freeContainers = e.containers.filter { !e.isMarked($0) }
        if !freeContainers.isEmpty {
            m.addItem(.separator())
            m.addItem(disabled("Docker containers — click to keep running"))
            for c in freeContainers {
                let i = item("   \(c.name) · \(c.image)", #selector(markContainer(_:)))
                i.representedObject = c.id
                m.addItem(i)
            }
        }

        // Unmarked agents
        let unmarked = e.detected.filter { !e.isMarked($0) }
        if !unmarked.isEmpty {
            m.addItem(.separator())
            m.addItem(disabled("Agents found — click to keep running"))
            for a in unmarked {
                let i = item("   \(a.agent) · PID \(a.proc.pid)", #selector(markAgent(_:)))
                i.representedObject = a.proc.pid
                m.addItem(i)
            }
            for name in e.agentKinds where !e.keepsEvery(name) {
                let i = item("   Always keep every \(name)", #selector(keepEvery(_:)))
                i.representedObject = name
                m.addItem(i)
            }
        }

        // Saver Mode
        m.addItem(.separator())
        let saverItem = NSMenuItem(title: "Saver Mode", action: nil, keyEquivalent: "")
        let ss = NSMenu()
        for trig in SaverTrigger.allCases {
            let i = item(trig.label, #selector(setTrigger(_:)))
            i.representedObject = trig.rawValue
            i.state = e.trigger == trig ? .on : .off
            ss.addItem(i)
        }
        ss.addItem(.separator())
        let opts: [(String, WritableKeyPath<SaverOptions, Bool>)] = [
            ("Pause unmarked apps", \.pauseApps), ("Turn off display", \.displayOff),
            ("Turn off Bluetooth", \.bluetoothOff), ("Turn off Wi-Fi", \.wifiOff),
            ("Low Power Mode on battery", \.lowPowerOnBattery),
            ("Mute speakers", \.muteSpeakers), ("Mute headphone jack", \.muteHeadphones),
        ]
        for (idx, o) in opts.enumerated() {
            let i = item(o.0, #selector(toggleSaverOption(_:)))
            i.tag = idx
            i.state = e.saver[keyPath: o.1] ? .on : .off
            ss.addItem(i)
        }
        if !e.restore.pausedApps.isEmpty {
            ss.addItem(.separator())
            ss.addItem(item("Resume All Apps Now", #selector(snooze)))
        }
        saverItem.submenu = ss
        m.addItem(saverItem)

        m.addItem(.separator())
        m.addItem(item("Check for Updates…", #selector(openReleases)))
        m.addItem(item("Quit AlwaysUp (restores everything)", #selector(quit), key: "q"))
    }

    private static let optionPaths: [WritableKeyPath<SaverOptions, Bool>] =
        [\.pauseApps, \.displayOff, \.bluetoothOff, \.wifiOff, \.lowPowerOnBattery, \.muteSpeakers, \.muteHeadphones]

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    // MARK: Menu actions

    @objc private func startUnlimited() { e.startManual(.some(nil)) }
    @objc private func startDefault() { e.startManual() }
    @objc private func startFor(_ s: NSMenuItem) { e.startManual(.some(s.representedObject as? TimeInterval)) }
    @objc private func stopManual() { e.stopManual() }
    @objc private func startUntilBattery(_ s: NSMenuItem) { if let p = s.representedObject as? Int { e.startManual(untilBattery: p) } }
    @objc private func toggleCharging() { e.onlyWhileCharging.toggle() }
    @objc private func restartTarget(_ s: NSMenuItem) { if let id = s.representedObject as? UUID { e.restartTarget(id) } }
    @objc private func resumeTarget(_ s: NSMenuItem) { if let id = s.representedObject as? UUID { e.resumeTarget(id) } }
    @objc private func removeTarget(_ s: NSMenuItem) { if let id = s.representedObject as? UUID { e.removeTarget(id) } }
    @objc private func markAgent(_ s: NSMenuItem) {
        if let pid = s.representedObject as? Int32, let a = e.detected.first(where: { $0.proc.pid == pid }) {
            e.addAgent(a, byName: false)
        }
    }
    @objc private func openReleases() {
        NSWorkspace.shared.open(URL(string: "https://github.com/SahejAgarwal05/AlwaysUp/releases")!)
    }
    @objc private func keepEvery(_ s: NSMenuItem) { if let n = s.representedObject as? String { e.setKeepEvery(n, true) } }
    @objc private func markContainer(_ s: NSMenuItem) {
        if let id = s.representedObject as? String, let c = e.containers.first(where: { $0.id == id }) { e.addContainer(c) }
    }
    @objc private func setTrigger(_ s: NSMenuItem) {
        if let raw = s.representedObject as? String, let t = SaverTrigger(rawValue: raw) { e.trigger = t }
    }
    @objc private func toggleSaverOption(_ s: NSMenuItem) {
        let path = Self.optionPaths[s.tag]
        if path == \SaverOptions.lowPowerOnBattery && !e.passwordless { openWindow(); return }
        e.saver[keyPath: path].toggle()
    }
    @objc private func snooze() { e.snoozeSaver() }
    @objc private func quit() { NSApp.terminate(nil) }
}

// `AlwaysUp run|done|busy …` — command-line use; exits without starting the app.
CLI.handle(CommandLine.arguments)

// `AlwaysUp --diagnose` prints what the app can see, without changing anything.
if CommandLine.arguments.contains("--diagnose") {
    let procs = Proc.all()
    let me = getuid()
    print("Processes: \(procs.count) total, \(procs.filter { $0.uid == me }.count) yours")
    for p in procs where p.uid == me {
        let args = Proc.args(p.pid)
        if let m = Agents.match(p, args: args) {
            print("  agent: \(m.name) pid=\(p.pid) ppid=\(p.ppid) \(args.joined(separator: " ").prefix(100))")
        }
    }
    print("Lid closed: \(Power.lidClosed())")
    print("Thermal state: \(ProcessInfo.processInfo.thermalState.rawValue) (0 nominal … 3 critical)")
    print("CPU time of this process: \(Proc.cpuTime(getpid()).map { String(format: "%.3fs", $0) } ?? "unavailable")")
    print("Helper grouping (responsible PID): \(Proc.responsiblePID(getpid()) != nil ? "available" : "unavailable")")
    print("Battery: \(Power.battery().map { "\($0.percent)% onBattery=\($0.onBattery)" } ?? "none")")
    print("SleepDisabled: \(Power.isSleepDisabled())")
    print("Battery lowpowermode: \(Power.batteryLowPower().map(String.init) ?? "unknown")")
    print("Bluetooth available=\(Radios.bluetoothAvailable) on=\(Radios.bluetoothOn)")
    print("Wi-Fi available=\(Radios.wifiAvailable) on=\(Radios.wifiOn)")
    print("Passwordless ready: \(Power.passwordlessReady())")
    if let cs = Docker.list() {
        print("Docker: reachable at \(Docker.socketPath ?? "?") · \(cs.count) container(s)")
        for c in cs { print("  container: \(c.name) \(c.image) \(c.state) \(c.status)") }
    } else {
        print("Docker: not reachable")
    }
    for o in Audio.builtInOutputs() {
        print("Audio out: \(o.name) headphones=\(o.isHeadphones) muted=\(Audio.isMuted(o.id).map(String.init) ?? "n/a")")
    }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
    app.run()
}
