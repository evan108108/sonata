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

/// True when `path` is inside `directory` (both standardized, symlinks
/// resolved), so `/plugins/sonar-old/bin` never matches `/plugins/sonar`.
func isPath(_ path: String, inside directory: String) -> Bool {
    let dir = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL.path
    let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    return file.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/")
}

/// True when a plugin's GET /api/health body names it: `{"app": "<name>", …}`.
func pluginIdentityMatches(healthBody: Data, name: String) -> Bool {
    guard let obj = try? JSONSerialization.jsonObject(with: healthBody) as? [String: Any],
          let app = obj["app"] as? String else { return false }
    return app == name
}
