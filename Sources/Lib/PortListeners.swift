import Foundation
import Darwin

/// PIDs that hold a TCP LISTEN socket on `port`, never including `selfPID`.
///
/// This replaced `lsof -ti :<port>`, which matches either end of a socket: it
/// also returned every process with a *client* connection to the port.
/// Sonata keeps one to each plugin (sonar's events channel on :4000,
/// keep-alive HTTP to the rest), so PluginManager.killProcessOnPort, which
/// SIGTERMs this list before every plugin spawn, signalled Sonata itself.
/// Hummingbird's ServiceGroup answered with a graceful shutdown, and the HTTP
/// supervisor logged "runService returned unexpectedly" (10/26 02:11Z,
/// 10/27 14:25Z). On 7/06 the same path escalated to SIGKILL on :4000. Only
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
