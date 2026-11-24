// Events.swift — system notifications that tell the Engine to look again right away,
// so it doesn't have to poll fast: lid / power events, battery changes, app launch & quit,
// wake from sleep, thermal changes, and requests from the command line.

import AppKit
import IOKit
import IOKit.ps

@MainActor
enum Events {
    private static var handler: (() -> Void)?
    private static var tokens: [Any] = []

    static func start(_ onEvent: @escaping () -> Void) {
        guard handler == nil else { return }
        handler = onEvent

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didWakeNotification] {
            tokens.append(ws.addObserver(forName: name, object: nil, queue: .main) { _ in Events.fire() })
        }
        tokens.append(NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in Events.fire() })
        tokens.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(Paths.requestNote), object: nil, queue: .main) { _ in Events.fire() })

        // Battery level / charger plugged or unplugged.
        if let src = IOPSNotificationCreateRunLoopSource({ _ in Events.fire() }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        }

        // Power-management messages (includes the lid opening and closing).
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        if svc != 0, let port = IONotificationPortCreate(kIOMainPortDefault) {
            IONotificationPortSetDispatchQueue(port, .main)
            var note: io_object_t = 0
            IOServiceAddInterestNotification(port, svc, kIOGeneralInterest, { _, _, _, _ in Events.fire() }, nil, &note)
            IOObjectRelease(svc)
        }
    }

    nonisolated static func fire() {
        DispatchQueue.main.async { MainActor.assumeIsolated { handler?() } }
    }
}
