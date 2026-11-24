import Foundation

/// The Antigravity CLI's (`agy`) data directory and the conversation a running process holds.
public enum AntigravityHome {
    public static func directory(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".gemini/antigravity-cli")
    }

    /// The conversation whose `presence/<id>.lock` the process keeps open; nil before its first prompt.
    /// shortcut: reads `/proc/<pid>/fd`, so a Mac host reports none; upgrade with libproc's PROC_PIDLISTFDS there.
    public static func conversationID(pid: Int32, directory: String) -> String? {
        let fds = "/proc/\(pid)/fd"
        let presence = (directory as NSString).appendingPathComponent("presence") + "/"
        for fd in (try? FileManager.default.contentsOfDirectory(atPath: fds)) ?? [] {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "\(fds)/\(fd)"),
                  target.hasPrefix(presence), target.hasSuffix(".lock")
            else { continue }
            return SessionLauncher.plainSessionID(String(target.dropFirst(presence.count).dropLast(".lock".count)))
        }
        return nil
    }
}
