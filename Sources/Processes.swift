// Processes.swift — listing processes and recognising AI agents.

import Darwin
import Foundation

struct ProcInfo: Identifiable, Hashable {
    let pid: Int32
    let ppid: Int32
    let uid: uid_t
    let comm: String     // kernel short name (max 16 chars)
    let path: String     // full executable path (only filled for the current user's processes)
    let start: Date
    var id: Int32 { pid }
    var displayName: String { path.isEmpty ? comm : (path as NSString).lastPathComponent }
}

enum Proc {
    private static func cstr<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// Every process on the system, in one sysctl call.
    static func all() -> [ProcInfo] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        size += size / 4
        let stride = MemoryLayout<kinfo_proc>.stride
        var buf = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
        guard sysctl(&mib, 4, &buf, &size, nil, 0) == 0 else { return [] }
        let me = getuid()
        return buf.prefix(size / stride).compactMap { kp in
            let pid = kp.kp_proc.p_pid
            guard pid > 0 else { return nil }
            let uid = kp.kp_eproc.e_ucred.cr_uid
            let st = kp.kp_proc.p_un.__p_starttime
            return ProcInfo(pid: pid, ppid: kp.kp_eproc.e_ppid, uid: uid,
                            comm: cstr(kp.kp_proc.p_comm),
                            path: uid == me ? path(pid) : "",
                            start: Date(timeIntervalSince1970: Double(st.tv_sec) + Double(st.tv_usec) / 1e6))
        }
    }

    static func path(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
        return String(cString: buf)
    }

    private static let timebase: Double = {
        var i = mach_timebase_info_data_t()
        mach_timebase_info(&i)
        return i.denom == 0 ? 1 : Double(i.numer) / Double(i.denom)
    }()

    /// Total CPU seconds (user + system) a process has used so far.
    static func cpuTime(_ pid: Int32) -> Double? {
        var ri = rusage_info_v2()
        let r = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard r == 0 else { return nil }
        return Double(ri.ri_user_time + ri.ri_system_time) * timebase / 1e9
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: ResponsibleFn? =
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
            .map { unsafeBitCast($0, to: ResponsibleFn.self) }

    /// The app a helper process works for (how Activity Monitor groups XPC helpers under their app).
    static func responsiblePID(_ pid: Int32) -> Int32? {
        guard let f = responsibleFn else { return nil }
        let r = f(pid)
        return r > 0 ? r : nil
    }

    /// argv of a process (works for the current user's processes).
    static func args(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }   // skip exec path
        while i < size && buf[i] == 0 { i += 1 }   // skip padding
        var out: [String] = []
        while out.count < argc && i < size {
            let s = i
            while i < size && buf[i] != 0 { i += 1 }
            out.append(String(decoding: buf[s..<i], as: UTF8.self))
            i += 1
        }
        return out
    }
}

// MARK: - Agent recognition

struct DetectedAgent: Identifiable, Hashable {
    let agent: String
    let proc: ProcInfo
    let command: String
    let isApp: Bool
    var id: Int32 { proc.pid }
}

enum Agents {
    /// (display name, executable names, substrings in the command line)
    static let cli: [(String, [String], [String])] = [
        ("Claude Code", ["claude"], ["@anthropic-ai/claude-code"]),
        ("Codex CLI", ["codex"], ["@openai/codex"]),
        ("Gemini CLI", ["gemini"], ["@google/gemini-cli"]),
        ("Aider", ["aider"], ["/bin/aider"]),
        ("Cursor Agent", ["cursor-agent"], []),
        ("OpenCode", ["opencode"], ["opencode-ai"]),
        ("Goose", ["goose"], []),
        ("Amp", ["amp"], ["@sourcegraph/amp"]),
        ("Copilot CLI", ["copilot"], ["@github/copilot"]),
        ("Qwen Code", ["qwen"], ["@qwen-code/"]),
        ("Crush", ["crush"], []),
        ("Cline", ["cline"], []),
        ("Open Interpreter", ["interpreter"], []),
        ("Ollama", ["ollama"], []),
    ]
    /// GUI apps that run agents.
    static let apps = ["Claude", "ChatGPT", "Codex", "Cursor", "Windsurf", "Ollama"]

    /// Programs that run a script given as their first argument (`node /path/to/gemini`).
    static let interpreters: Set<String> = [
        "node", "bun", "bunx", "deno", "npx", "tsx", "ruby", "uv", "uvx", "pipx", "sh", "bash", "zsh", "env",
    ]

    /// `custom` = extra process names the user wants treated as agents.
    static func match(_ p: ProcInfo, args: [String], custom: [String] = []) -> (name: String, isApp: Bool)? {
        for app in apps where p.path.hasSuffix("/\(app).app/Contents/MacOS/\(app)") { return (app, true) }
        if p.path.contains(".app/") { return nil }

        let exe = p.displayName.lowercased()
        var names = Set<String>([exe, p.comm.lowercased()])
        if let a0 = args.first { names.insert((a0 as NSString).lastPathComponent.lowercased()) }
        // Only look at the first argument when it's the script being run — `less claude` is not Claude.
        if args.count > 1, interpreters.contains(exe) || exe.hasPrefix("python") {
            names.insert((args[1] as NSString).lastPathComponent.lowercased())
        }
        let line = args.joined(separator: " ").lowercased()
        if line.contains("native-host") { return nil }   // browser bridge helpers, not agents
        for c in custom where names.contains(c.lowercased()) { return (c, false) }
        for (label, execs, needles) in cli {
            if execs.contains(where: names.contains) || needles.contains(where: line.contains) { return (label, false) }
        }
        return nil
    }
}
