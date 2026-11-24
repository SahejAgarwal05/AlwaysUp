// A do-nothing GUI app used by the self-test as a stand-in for "your other apps".
// Pass `child` to make it spawn a `sleep` child (simulates a terminal running an agent).

import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
var child: Process?
if CommandLine.arguments.contains("child") {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sleep")
    p.arguments = ["900"]
    try? p.run()
    child = p
}
app.run()
