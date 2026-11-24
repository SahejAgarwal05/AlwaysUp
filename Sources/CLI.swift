// CLI.swift — command-line front end.
//
//   AlwaysUp run [--for 2h] [--then release|pause|quit] <command> [args…]
//       Keeps the Mac awake while <command> runs (like `caffeinate`, but lid-closed too).
//   AlwaysUp done    — "the agent I'm running inside has finished its turn" (e.g. a Claude Code Stop hook)
//   AlwaysUp simulate lid=closed battery=15   — pretend, for trying the app out; `simulate off` ends it
//   AlwaysUp busy    — "…and now it's working again"                        (e.g. a UserPromptSubmit hook)
//
// These only drop a small request file for the running app, so they return instantly.

import AppKit

enum CLI {
    private static let usage = """
    Usage:
      AlwaysUp run [--for <time>] [--then release|pause|quit] <command> [args…]
          Keep the Mac awake while <command> runs. <time> is e.g. 45m, 2h, 1h30m.
      AlwaysUp done     Tell AlwaysUp the agent this runs inside is waiting for you.
      AlwaysUp busy     Tell AlwaysUp it's working again.
      AlwaysUp simulate [lid=closed|open] [display=yes|no] [battery=15|15+] [thermal=hot|normal]
          Make the running app believe this, to try it out at your desk. `simulate off` ends it.
      AlwaysUp --diagnose
    """

    /// Handles a CLI command and exits. Returns only when the arguments aren't one.
    static func handle(_ argv: [String]) {
        guard argv.count > 1 else { return }
        switch argv[1] {
        case "run": run(Array(argv.dropFirst(2)))
        case "done", "busy":
            let explicit = argv.count > 2 ? Int32(argv[2]) : nil
            send(Request(cmd: argv[1], pids: explicit.map { [$0] } ?? ancestors()))
            exit(0)
        case "simulate":
            var sim: [String: String] = [:]
            for a in argv.dropFirst(2) where a != "off" {
                let kv = a.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2, ["lid", "display", "battery", "thermal"].contains(kv[0]) else {
                    fail("can't read '\(a)'\n\(usage)")
                }
                sim[kv[0]] = kv[1]
            }
            guard argv.count > 2 else { fail("nothing to simulate\n\(usage)") }
            send(Request(cmd: "simulate", pids: [], sim: sim))
            exit(0)
        case "help", "--help", "-h":
            print(usage); exit(0)
        default: return
        }
    }

    /// "45m", "2h", "1h30m", "90" (minutes) → seconds.
    static func parseDuration(_ text: String) -> TimeInterval? {
        let t = text.lowercased()
        if let minutes = Double(t) { return minutes > 0 ? minutes * 60 : nil }
        var total = 0.0, digits = ""
        for ch in t {
            if ch.isNumber || ch == "." { digits.append(ch); continue }
            guard let n = Double(digits) else { return nil }
            switch ch {
            case "d": total += n * 86400
            case "h": total += n * 3600
            case "m": total += n * 60
            case "s": total += n
            default: return nil
            }
            digits = ""
        }
        return digits.isEmpty && total > 0 ? total : nil
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("AlwaysUp: \(message)\n".utf8))
        exit(64)
    }

    private static func run(_ args: [String]) -> Never {
        var rest = args[...]
        var limit: TimeInterval?
        var action: ExpireAction?
        while let a = rest.first, a.hasPrefix("--") {
            rest = rest.dropFirst()
            if a == "--" { break }
            guard let value = rest.first else { fail("\(a) needs a value") }
            rest = rest.dropFirst()
            switch a {
            case "--for":
                guard let d = parseDuration(value) else { fail("can't read the time '\(value)' (try 45m, 2h, 1h30m)") }
                limit = d
            case "--then":
                guard let x = ExpireAction(rawValue: value) else { fail("--then must be release, pause or quit") }
                action = x
            default: fail("unknown option \(a)\n\(usage)")
            }
        }
        guard let command = rest.first else { fail("nothing to run\n\(usage)") }

        // This process *becomes* the command (same PID), so register ourselves, then exec.
        send(Request(cmd: "keep", pids: [getpid()], name: (command as NSString).lastPathComponent,
                     limit: limit, action: action))
        launchAppIfNeeded()

        var cargs: [UnsafeMutablePointer<CChar>?] = rest.map { strdup($0) }
        cargs.append(nil)
        execvp(command, &cargs)
        FileHandle.standardError.write(Data("AlwaysUp: can't run \(command): \(String(cString: strerror(errno)))\n".utf8))
        exit(127)
    }

    /// PIDs of the processes this command was started from (parent, grandparent, …).
    private static func ancestors() -> [Int32] {
        let parent = Dictionary(Proc.all().map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a })
        var chain: [Int32] = [], cur = getppid()
        while cur > 1, chain.count < 40 {
            chain.append(cur)
            cur = parent[cur] ?? 0
        }
        return chain
    }

    private static func send(_ r: Request) {
        let dir = Paths.requests(in: Paths.supportDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(r) else { return }
        try? data.write(to: dir.appendingPathComponent("\(getpid())-\(r.cmd).json"), options: .atomic)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(Paths.requestNote), object: nil, userInfo: nil, deliverImmediately: true)
    }

    private static func launchAppIfNeeded() {
        let me = getpid()
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Paths.bundleID)
            .contains { $0.processIdentifier != me }
        let bundle = Bundle.main.bundlePath
        guard !running, bundle.hasSuffix(".app") else { return }
        Power.run("/usr/bin/open", ["-gj", bundle])
    }
}
