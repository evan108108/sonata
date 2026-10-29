import Foundation
import Darwin

/// PIDs that hold a TCP LISTEN socket on `port`, never including `selfPID`.
///
/// This replaced `lsof -ti :<port>`, which matches either end of a socket: it
/// also returned every process with a *client* connection to the port.
/// Sonata keeps one to each plugin (sonar's events channel,
/// keep-alive HTTP to the rest), so PluginManager.killProcessOnPort, which
/// SIGTERMs this list before every plugin spawn, signalled Sonata itself.
/// Hummingbird's ServiceGroup answered with a graceful shutdown, and the HTTP
/// supervisor logged "runService returned unexpectedly" (10/26 02:11Z,
/// 10/27 14:25Z). On 7/06 the same path escalated to SIGKILL on sonar's port. Only
/// the listener holds the port a fresh spawn needs to bind.
func tcpListenerPIDs(port: Int, excluding selfPID: pid_t = getpid()) -> [pid_t] {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    proc.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
    } catch {
        return []
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return parseLsofPIDs(String(decoding: data, as: UTF8.self), excluding: selfPID)
}

/// Parse `lsof -t` output (one pid per line), dropping duplicates and `selfPID`.
func parseLsofPIDs(_ output: String, excluding selfPID: pid_t) -> [pid_t] {
    var seen = Set<pid_t>()
    var pids: [pid_t] = []
    for line in output.split(separator: "\n") {
        guard let pid = pid_t(line.trimmingCharacters(in: .whitespaces)),
              pid != selfPID, seen.insert(pid).inserted else { continue }
        pids.append(pid)
    }
    return pids
}

/// True when `port` can be bound on INADDR_ANY right now.
///
/// A real bind, not `lsof`: `lsof` run as the current user can't see
/// listeners owned by other users, and NoMachine's nxd holds *:4000 as root.
/// That blind spot is how sonar died with eaddrinuse after the 10/29 reboot
/// while PluginManager saw the port as free.
func tcpPortIsFree(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)
    addr.sin_addr.s_addr = INADDR_ANY
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return bound == 0
}

/// The port to hand a dynamic-port plugin: `preferred` (its last bound port,
/// so it stays put across restarts) when free and inside `range`, else the
/// first free port in `range`, else nil when the whole range is held.
func pickPluginPort(
    preferred: Int?,
    range: ClosedRange<Int>,
    isFree: (Int) -> Bool = tcpPortIsFree
) -> Int? {
    if let preferred, range.contains(preferred), isFree(preferred) { return preferred }
    return range.first { $0 != preferred && isFree($0) }
}

/// Absolute path of `pid`'s executable, or nil if it can't be read (gone,
/// or owned by another user). Used to make sure a pid is ours before we
/// signal it.
func executablePath(of pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// `pid`'s environment as launched, or nil if it can't be read (gone, or
/// owned by another user: KERN_PROCARGS2 is denied across users, so root's
/// nxd stays unreadable).
func processEnvironment(of pid: pid_t) -> [String: String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
    return parseProcArgs2Environment(Array(buffer.prefix(size)))
}

/// The environment out of a KERN_PROCARGS2 buffer: an Int32 argc, the exec
/// path, NUL padding, argc NUL-terminated args, then NUL-terminated
/// `KEY=value` strings up to the first empty one.
func parseProcArgs2Environment(_ bytes: [UInt8]) -> [String: String]? {
    let argcSize = MemoryLayout<Int32>.size
    guard bytes.count >= argcSize else { return nil }
    let argc = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
    var i = argcSize
    while i < bytes.count, bytes[i] != 0 { i += 1 }   // exec path
    while i < bytes.count, bytes[i] == 0 { i += 1 }   // padding
    var skipped = 0
    while i < bytes.count, skipped < argc {           // argv
        while i < bytes.count, bytes[i] != 0 { i += 1 }
        i += 1
        skipped += 1
    }
    guard skipped == argc else { return nil }
    var env: [String: String] = [:]
    while i < bytes.count, bytes[i] != 0 {
        let start = i
        while i < bytes.count, bytes[i] != 0 { i += 1 }
        let entry = String(decoding: bytes[start..<i], as: UTF8.self)
        if let eq = entry.firstIndex(of: "=") {
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        i += 1
    }
    return env
}

/// True when `path` is inside `directory` (both standardized, symlinks
/// resolved), so `/plugins/sonar-old/bin` never matches `/plugins/sonar`.
func isPath(_ path: String, inside directory: String) -> Bool {
    let dir = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL.path
    let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    return file.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/")
}

/// True when `a` and `b` name the same directory (standardized, symlinks resolved).
func isSameDirectory(_ a: String, _ b: String) -> Bool {
    let norm = { (p: String) -> String in
        let s = URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path
        return s.count > 1 && s.hasSuffix("/") ? String(s.dropLast()) : s
    }
    return norm(a) == norm(b)
}

/// True when `pid` is a process Sonata spawned for the plugin at
/// `pluginPath`: its executable lives in the plugin dir (a release or
/// compiled binary), or it carries the `SONATA_PLUGIN_DATA_DIR` Sonata sets
/// on every plugin spawn. The env marker is what catches interpreter-run
/// plugins — prstar and lead-tracker exec `node`, whose executable is under
/// Homebrew or nvm, and prstar's script isn't even in its plugin dir.
/// macOS hides a platform binary's environment (/bin/sleep, /bin/bash), so
/// the marker only works for processes like node, which is what plugins run.
func processBelongsToPlugin(
    _ pid: pid_t,
    pluginPath: String,
    executable: (pid_t) -> String? = executablePath,
    environment: (pid_t) -> [String: String]? = processEnvironment
) -> Bool {
    if let exe = executable(pid), isPath(exe, inside: pluginPath) { return true }
    if let dataDir = environment(pid)?["SONATA_PLUGIN_DATA_DIR"] {
        return isSameDirectory(dataDir, pluginPath)
    }
    return false
}

/// True when a plugin's GET /api/health body names it: `{"app": "<name>", …}`.
func pluginIdentityMatches(healthBody: Data, name: String) -> Bool {
    guard let obj = try? JSONSerialization.jsonObject(with: healthBody) as? [String: Any],
          let app = obj["app"] as? String else { return false }
    return app == name
}
