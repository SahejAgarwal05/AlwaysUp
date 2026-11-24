// Docker.swift — find running Docker containers via the Docker Engine API (Unix socket).
// Works with Docker Desktop, OrbStack, Colima, Rancher Desktop and Podman (Docker-compatible socket).

import Darwin
import Foundation

struct Container: Identifiable, Hashable {
    let id: String
    let name: String
    let image: String
    let state: String      // running, paused, exited…
    let status: String     // "Up 2 hours"
    var shortID: String { String(id.prefix(12)) }
    var isRunning: Bool { state == "running" }
}

enum Docker {
    /// Candidate sockets, in order. `DOCKER_HOST=unix:///path` wins if set.
    static var socketCandidates: [String] {
        let home = NSHomeDirectory()
        var list: [String] = []
        if let host = ProcessInfo.processInfo.environment["DOCKER_HOST"], host.hasPrefix("unix://") {
            list.append(String(host.dropFirst("unix://".count)))
        }
        list += [
            "\(home)/.docker/run/docker.sock",                  // Docker Desktop
            "\(home)/.orbstack/run/docker.sock",                // OrbStack
            "\(home)/.colima/default/docker.sock",              // Colima
            "\(home)/.colima/docker.sock",
            "\(home)/.rd/docker.sock",                          // Rancher Desktop
            "\(home)/.local/share/containers/podman/machine/podman.sock",
            "/var/run/docker.sock",
        ]
        return list
    }

    /// Process / app names that make up the container runtime. Kept items that are containers
    /// protect these from Saver Mode, otherwise pausing the runtime would freeze the container.
    static let runtimeProcessNames: Set<String> = [
        "com.docker.backend", "com.docker.virtualization", "com.docker.vpnkit", "com.docker.krun",
        "com.docker.build", "Docker Desktop", "Docker", "OrbStack", "OrbStack Helper", "limactl",
        "colima", "qemu-system-aarch64", "qemu-system-x86_64", "Rancher Desktop", "podman", "gvproxy", "vfkit",
    ]
    static let runtimeBundleIDs: Set<String> = [
        "com.docker.docker", "dev.kdrag0n.MacVirt", "io.rancherdesktop.app", "com.github.containers.podman-desktop",
    ]

    private static let lock = NSLock()
    private static var _socketPath: String?
    /// The socket that last answered (read and written from both the main and the polling thread).
    private(set) static var socketPath: String? {
        get { lock.lock(); defer { lock.unlock() }; return _socketPath }
        set { lock.lock(); _socketPath = newValue; lock.unlock() }
    }

    // MARK: HTTP over a Unix socket

    /// Minimal HTTP/1.0 request (no keep-alive, no chunking). Returns (status, body) or nil if unreachable.
    static func request(_ method: String, _ path: String, socket sock: String, timeout: Int = 2) -> (Int, Data)? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard sock.utf8.count < maxLen else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: sock.utf8)
            raw[sock.utf8.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { return nil }

        let req = "\(method) \(path) HTTP/1.0\r\nHost: docker\r\nContent-Length: 0\r\n\r\n"
        guard req.withCString({ send(fd, $0, strlen($0), 0) }) > 0 else { return nil }

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            data.append(buf, count: n)
            if data.count > 8_000_000 { break }
        }
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<sep.lowerBound], encoding: .utf8) else { return nil }
        let parts = head.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        return (status, data[sep.upperBound...])
    }

    private static func call(_ method: String, _ path: String) -> (Int, Data)? {
        if let s = socketPath, let r = request(method, path, socket: s) { return r }
        // (Re)discover the socket.
        for s in socketCandidates where FileManager.default.fileExists(atPath: s) {
            if let r = request(method, path, socket: s) { socketPath = s; return r }
        }
        socketPath = nil
        return nil
    }

    // MARK: API

    /// Containers (running and paused). nil = no Docker runtime reachable.
    static func list() -> [Container]? {
        guard let (status, body) = call("GET", "/containers/json?all=1"), status == 200,
              let arr = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else { return nil }
        return arr.compactMap { c in
            guard let id = c["Id"] as? String else { return nil }
            let name = ((c["Names"] as? [String])?.first ?? id).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return Container(id: id, name: name, image: c["Image"] as? String ?? "",
                             state: c["State"] as? String ?? "", status: c["Status"] as? String ?? "")
        }
        .filter { $0.state == "running" || $0.state == "paused" }
    }

    @discardableResult static func pause(_ id: String) -> Bool { ok(call("POST", "/containers/\(id)/pause")) }
    @discardableResult static func unpause(_ id: String) -> Bool { ok(call("POST", "/containers/\(id)/unpause")) }
    @discardableResult static func stop(_ id: String) -> Bool { ok(call("POST", "/containers/\(id)/stop?t=10")) }

    private static func ok(_ r: (Int, Data)?) -> Bool { r.map { (200..<300).contains($0.0) } ?? false }
}
