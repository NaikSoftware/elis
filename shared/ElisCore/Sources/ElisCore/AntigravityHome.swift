#if canImport(Darwin)
import Darwin
#endif
import Foundation

/// The Antigravity CLI's (`agy`) data directory and the conversation a running process holds.
public enum AntigravityHome {
    public static func directory(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".gemini/antigravity-cli")
    }

    /// The conversation whose `presence/<id>.lock` the process keeps open; nil before its first prompt.
    public static func conversationID(pid: Int32, directory: String) -> String? {
        let presence = (directory as NSString).appendingPathComponent("presence") + "/"
        return openPaths(pid: pid).lazy
            .filter { $0.hasPrefix(presence) && $0.hasSuffix(".lock") }
            .compactMap { SessionLauncher.plainSessionID(String($0.dropFirst(presence.count).dropLast(".lock".count))) }
            .first
    }

    /// The paths of the files `pid` holds open: libproc on a Mac, `/proc/<pid>/fd` elsewhere.
    static func openPaths(pid: Int32) -> [String] {
        #if canImport(Darwin)
        let listed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard listed > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(listed) / stride)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        return fds.prefix(Int(filled) / stride).compactMap { fd -> String? in
            guard fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { return nil }
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
            return withUnsafeBytes(of: info.pvip.vip_path) { bytes in String(decoding: bytes.prefix { byte in byte != 0 }, as: UTF8.self) }
        }
        #else
        let fds = "/proc/\(pid)/fd"
        return ((try? FileManager.default.contentsOfDirectory(atPath: fds)) ?? []).compactMap {
            try? FileManager.default.destinationOfSymbolicLink(atPath: "\(fds)/\($0)")
        }
        #endif
    }
}
