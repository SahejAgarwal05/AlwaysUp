// Power.swift — sleep control (pmset), low power, display, radios, battery, lid state, admin helpers.

import AppKit
import CoreWLAN
import IOKit
import IOKit.ps

enum Power {
    static let sudoersPath = "/etc/sudoers.d/alwaysup"
    static let pmset = "/usr/bin/pmset"

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        // Wait on a semaphore rather than `waitUntilExit()`: that one spins the run loop, which would let
        // timers and queued ticks run in the middle of whatever called us.
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Runs a shell command as root using the standard macOS admin password dialog.
    static func runAsAdmin(_ shellCommand: String) -> Bool {
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var err: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?
            .executeAndReturnError(&err)
        return err == nil
    }

    private static func sudoPmset(_ args: [String]) -> Bool {
        run("/usr/bin/sudo", ["-n", pmset] + args).status == 0
    }

    // MARK: Sleep

    /// Sets `disablesleep` (blocks lid-close sleep). Passwordless if the sudoers rule is installed.
    static func setSleepDisabled(_ on: Bool, prompt: Bool = true) -> Bool {
        let v = on ? "1" : "0"
        if sudoPmset(["-a", "disablesleep", v]) { return true }
        guard prompt else { return false }
        return runAsAdmin("\(pmset) -a disablesleep \(v)")
    }

    static func isSleepDisabled() -> Bool {
        for line in run(pmset, ["-g"]).output.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.trimmingCharacters(in: .whitespaces).hasSuffix("1")
        }
        return false
    }

    // MARK: Low Power Mode (battery profile only)

    /// Current `lowpowermode` value of the Battery Power profile.
    static func batteryLowPower() -> Int? {
        var inBattery = false
        for raw in run(pmset, ["-g", "custom"]).output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(":") { inBattery = line.hasPrefix("Battery Power"); continue }
            if inBattery, line.hasPrefix("lowpowermode") {
                return Int(line.split(separator: " ", omittingEmptySubsequences: true).last ?? "")
            }
        }
        return nil
    }

    /// Never prompts — this runs automatically (often with the lid closed), so it needs passwordless mode.
    static func setBatteryLowPower(_ v: Int) -> Bool { sudoPmset(["-b", "lowpowermode", "\(v)"]) }

    // MARK: Display

    static func displaySleepNow() { run(pmset, ["displaysleepnow"]) }

    /// After sleep is re-enabled with the lid already shut, macOS can sit awake until its idle
    /// timer fires. Send it to sleep now — but only if the lid really is closed and no monitor is in use.
    static func sleepNowIfLidClosed() {
        guard lidClosed(), !externalDisplayConnected() else { return }
        run(pmset, ["sleepnow"])
    }

    // MARK: Passwordless mode

    /// True when every command AlwaysUp needs can run via sudo without a password.
    static func passwordlessReady() -> Bool {
        run("/usr/bin/sudo", ["-n", "-l", pmset, "-a", "disablesleep", "1"]).status == 0 &&
        run("/usr/bin/sudo", ["-n", "-l", pmset, "-b", "lowpowermode", "1"]).status == 0
    }

    static var passwordlessFileExists: Bool { FileManager.default.fileExists(atPath: sudoersPath) }

    static func installPasswordless() -> Bool {
        let cmds = ["-a disablesleep 0", "-a disablesleep 1", "-b lowpowermode 0", "-b lowpowermode 1"]
            .map { "\(pmset) \($0)" }.joined(separator: ", ")
        let rule = "\(NSUserName()) ALL=(root) NOPASSWD: \(cmds)\n"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("alwaysup.sudoers")
        guard (try? rule.write(to: tmp, atomically: true, encoding: .utf8)) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: tmp) }
        return runAsAdmin("/usr/sbin/visudo -cf '\(tmp.path)' && /usr/bin/install -m 0440 -o root -g wheel '\(tmp.path)' \(sudoersPath)")
    }

    static func removePasswordless() -> Bool { runAsAdmin("/bin/rm -f \(sudoersPath)") }

    // MARK: Lid & battery

    /// True when the laptop lid is closed.
    static func lidClosed() -> Bool {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard svc != 0 else { return false }
        defer { IOObjectRelease(svc) }
        let v = IORegistryEntryCreateCFProperty(svc, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (v as? Bool) ?? false
    }

    /// True when an external display is connected (lid closed + monitor = you're probably still using it).
    static func externalDisplayConnected() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    static func battery() -> Battery? {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(snap, src)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return Battery(onBattery: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue,
                           percent: cur * 100 / max)
        }
        return nil
    }
}

struct Battery: Equatable { let onBattery: Bool; let percent: Int }

// MARK: - Bluetooth & Wi-Fi

enum Radios {
    private typealias GetFn = @convention(c) () -> Int32
    private typealias SetFn = @convention(c) (Int32) -> Void
    private static let bt = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)
    private static let btGet: GetFn? = bt.flatMap { dlsym($0, "IOBluetoothPreferenceGetControllerPowerState") }
        .map { unsafeBitCast($0, to: GetFn.self) }
    private static let btSet: SetFn? = bt.flatMap { dlsym($0, "IOBluetoothPreferenceSetControllerPowerState") }
        .map { unsafeBitCast($0, to: SetFn.self) }

    static var bluetoothAvailable: Bool { btGet != nil && btSet != nil }
    static var bluetoothOn: Bool { (btGet?() ?? 0) != 0 }
    static func setBluetooth(_ on: Bool) { btSet?(on ? 1 : 0) }

    private static var wifiInterface: CWInterface? { CWWiFiClient.shared().interface() }
    static var wifiAvailable: Bool { wifiInterface != nil }
    static var wifiOn: Bool { wifiInterface?.powerOn() ?? false }

    @discardableResult
    static func setWiFi(_ on: Bool) -> Bool {
        guard let iface = wifiInterface else { return false }
        if (try? iface.setPower(on)) != nil { return true }
        guard let name = iface.interfaceName else { return false }
        return Power.run("/usr/sbin/networksetup", ["-setairportpower", name, on ? "on" : "off"]).status == 0
    }
}

// MARK: - Misc helpers

@MainActor
func showAlert(_ title: String, _ text: String) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    NSApp.activate(ignoringOtherApps: true)
    a.runModal()
}

func formatDuration(_ t: TimeInterval) -> String {
    let s = max(0, Int(t.rounded()))
    let h = s / 3600, m = (s % 3600) / 60
    if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
    if m > 0 { return "\(m)m" }
    return "\(s)s"
}
