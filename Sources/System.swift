// System.swift — everything the Engine asks of the outside world, in one swappable struct.
// The real app uses the defaults; the unit tests replace them with a fake Mac.

import AppKit
import CoreAudio

struct AppInfo: Hashable {
    let pid: Int32
    let bundleID: String?
    let name: String
    let regular: Bool          // a normal Dock app (not a menu bar / background app)
    let bundlePath: String?
}

/// One reading of the things that are polled (gathered off the main thread).
struct Snapshot {
    var procs: [ProcInfo] = []
    var lidClosed = false
    var externalDisplay = false
    var battery: Battery?
    /// nil = no Docker runtime reachable. Only meaningful when `dockerPolled`.
    var containers: [Container]?
    var dockerPolled = false
    var thermal: ProcessInfo.ThermalState = .nominal

    static func gather(docker: Bool) -> Snapshot {
        Snapshot(procs: Proc.all(), lidClosed: Power.lidClosed(),
                 externalDisplay: Power.externalDisplayConnected(), battery: Power.battery(),
                 containers: docker ? Docker.list() : nil, dockerPolled: docker,
                 thermal: ProcessInfo.processInfo.thermalState)
    }
}

struct System {
    /// false in unit tests: no timers, observers, helper processes or real notifications.
    var live = true
    var now: () -> Date = { Date() }

    // Polled state
    var snapshot: (_ docker: Bool) -> Snapshot = { Snapshot.gather(docker: $0) }
    var procs: () -> [ProcInfo] = { Proc.all() }
    var apps: @MainActor () -> [AppInfo] = {
        NSWorkspace.shared.runningApplications.map {
            AppInfo(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier,
                    name: $0.localizedName ?? $0.bundleIdentifier ?? "",
                    regular: $0.activationPolicy == .regular, bundlePath: $0.bundleURL?.path)
        }
    }
    var args: (Int32) -> [String] = { Proc.args($0) }
    var cpuTime: (Int32) -> Double? = { Proc.cpuTime($0) }
    var responsible: (Int32) -> Int32? = { Proc.responsiblePID($0) }

    // Processes
    var signal: (Int32, Int32) -> Void = { _ = kill($0, $1) }
    var terminateApp: @MainActor (String) -> Void = { b in
        NSRunningApplication.runningApplications(withBundleIdentifier: b).forEach { $0.terminate() }
    }

    // Power
    var setSleepDisabled: (_ on: Bool, _ prompt: Bool) -> Bool = { Power.setSleepDisabled($0, prompt: $1) }
    var isSleepDisabled: () -> Bool = { Power.isSleepDisabled() }
    var passwordlessReady: () -> Bool = { Power.passwordlessReady() }
    var batteryLowPower: () -> Int? = { Power.batteryLowPower() }
    var setBatteryLowPower: (Int) -> Bool = { Power.setBatteryLowPower($0) }
    var displaySleepNow: () -> Void = { Power.displaySleepNow() }
    var sleepNow: () -> Void = { Power.sleepNowIfLidClosed() }

    // Radios
    var bluetoothAvailable: () -> Bool = { Radios.bluetoothAvailable }
    var bluetoothOn: () -> Bool = { Radios.bluetoothOn }
    var setBluetooth: (Bool) -> Void = { Radios.setBluetooth($0) }
    var wifiAvailable: () -> Bool = { Radios.wifiAvailable }
    var wifiOn: () -> Bool = { Radios.wifiOn }
    var setWiFi: (Bool) -> Void = { Radios.setWiFi($0) }

    // Audio
    var audioOutputs: () -> [Audio.Output] = { Audio.builtInOutputs() }
    var isMuted: (AudioDeviceID) -> Bool? = { Audio.isMuted($0) }
    var setMuted: (AudioDeviceID, Bool) -> Void = { Audio.setMuted($0, $1) }

    // Docker
    var dockerList: () -> [Container]? = { Docker.list() }
    var dockerPause: (String) -> Bool = { Docker.pause($0) }
    var dockerUnpause: (String) -> Bool = { Docker.unpause($0) }
    var dockerStop: (String) -> Bool = { Docker.stop($0) }

    // Phone notifications
    var push: (_ url: String, _ title: String, _ body: String) -> Void = { Push.send($0, title: $1, body: $2) }
}

// MARK: - Shared paths and the command-line request format

enum Paths {
    static let bundleID = "local.alwaysup"
    /// Posted (as a distributed notification) to make the running app look at its requests folder now.
    static let requestNote = "local.alwaysup.request"

    static var supportDir: URL {
        ProcessInfo.processInfo.environment["ALWAYSUP_SUPPORT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AlwaysUp", isDirectory: true)
    }
    static func requests(in dir: URL) -> URL { dir.appendingPathComponent("requests", isDirectory: true) }
}

/// Written by `AlwaysUp run|done|busy` into the requests folder; read by the running app.
struct Request: Codable {
    var cmd: String                // keep, done, busy
    var pids: [Int32]              // keep: the process. done/busy: the caller's ancestors.
    var name: String?
    var limit: TimeInterval?
    var action: ExpireAction?
    /// simulate: lid / display / battery / thermal values to pretend (empty = back to real).
    var sim: [String: String]? = nil
}

// MARK: - Phone notifications (ntfy-style: POST the text, title in a header)

enum Push {
    static func isValid(_ url: String) -> Bool {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespaces)), u.host != nil else { return false }
        return ["http", "https"].contains(u.scheme?.lowercased() ?? "")
    }

    static func send(_ url: String, title: String, body: String) {
        guard isValid(url), let u = URL(string: url.trimmingCharacters(in: .whitespaces)) else { return }
        var r = URLRequest(url: u, timeoutInterval: 15)
        r.httpMethod = "POST"
        r.setValue(title, forHTTPHeaderField: "Title")
        r.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data(body.utf8)
        URLSession.shared.dataTask(with: r).resume()
    }
}
