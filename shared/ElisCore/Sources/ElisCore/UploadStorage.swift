import Foundation
#if canImport(Musl)
import Musl
#endif

public enum UploadLimits {
    public static let maxBytes = 20_971_520
    public static let maxFiles = 10
}

/// ControlUpload is `session.upload`'s answer: a reserved `path` on this host, or the `host` and its `session` id
/// that hold the row's files.
public struct ControlUpload: Codable, Sendable, Equatable {
    public var path: String?
    public var host: String?
    public var session: String?

    public init(path: String? = nil, host: String? = nil, session: String? = nil) {
        self.path = path
        self.host = host
        self.session = session
    }
}

/// UploadStorage owns `<stateDir>/uploads/<sessionID>/`, where files sent from the phone land.
public enum UploadStorage {
    private static let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")

    public static func safeName(_ raw: String) -> String {
        var name = raw.map { allowed.contains($0) ? $0 : "_" }
        if name.first == "-" || name.first == "." { name[0] = "_" }
        return name.isEmpty ? "file" : String(name.prefix(100))
    }

    public static func fileName(_ raw: String, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-"
        return formatter.string(from: now) + safeName(raw)
    }

    /// reserve claims a fresh name as an empty placeholder, so two uploads of one name never share a file.
    public static func reserve(stateDir: URL, sessionID: String, name: String, now: Date) throws -> URL {
        let folder = stateDir.appendingPathComponent("uploads", isDirectory: true).appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = fileName(name, now: now) as NSString
        for attempt in 1...1000 {
            let candidate = attempt == 1 ? base as String
                : base.pathExtension.isEmpty ? "\(base)-\(attempt)" : "\(base.deletingPathExtension)-\(attempt).\(base.pathExtension)"
            let url = folder.appendingPathComponent(candidate)
            let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
            if fd >= 0 {
                close(fd)
                return url
            }
            guard errno == EEXIST else { throw posixError() }
        }
        throw POSIXError(.EEXIST)
    }

    /// sweep removes every folder `keep` lacks (compared case-insensitively) and files older than `maxAge`;
    /// a nil `keep` means the host could not list its sessions, so no folder goes.
    public static func sweep(stateDir: URL, keep: Set<String>?, now: Date, maxAge: TimeInterval = 7 * 86_400) {
        let manager = FileManager.default
        let kept = keep.map { Set($0.map { $0.lowercased() }) }
        let root = stateDir.appendingPathComponent("uploads", isDirectory: true)
        for folder in (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            if let kept, !kept.contains(folder.lastPathComponent.lowercased()) {
                try? manager.removeItem(at: folder)
                continue
            }
            for file in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      now.timeIntervalSince(modified) > maxAge else { continue }
                try? manager.removeItem(at: file)
            }
        }
    }

    /// keep is the sweep's keep set: the sessions holding panes and every session a Recent Closed entry reopens,
    /// nil when the claim walk could not account for every saved window.
    public static func keep(claims: ZmxClaimWalk, recent: [RecentClosedItem]) -> Set<String>? {
        guard claims.complete else { return nil }
        return Set((claims.claims.map(\.sessionID) + recent.flatMap(\.restoredSessionIDs)).map(\.uuidString))
    }

    /// answer is `session.upload` for a resolved row: a page refuses, a row from another host names that host.
    @MainActor
    public static func answer(for session: Session, stateDir: URL, name: String, now: Date) -> ControlResponse {
        if session.content == .page { return PageSessionRefusal.response(.sessionUpload) }
        var result = ControlResult()
        if let host = session.remoteHost {
            result.upload = ControlUpload(host: host, session: session.remoteSessionID)
        } else {
            do {
                result.upload = ControlUpload(path: try reserve(stateDir: stateDir, sessionID: session.id.uuidString, name: name, now: now).path)
            } catch {
                return ControlResponse(ok: false, error: "could not reserve an upload path: \(error.localizedDescription)")
            }
        }
        return ControlResponse(ok: true, result: result)
    }

    static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// UploadSink writes `<path>.part` and moves it over the reserved placeholder once every byte is in.
public final class UploadSink {
    public let path: URL
    private let part: String
    private let handle: FileHandle

    public init(path: URL) throws {
        self.path = path
        part = path.path + ".part"
        let fd = open(part, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw UploadStorage.posixError() }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    public func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
    }

    public func finish() throws -> URL {
        try handle.close()
        guard rename(part, path.path) == 0 else { throw UploadStorage.posixError() }
        return path
    }

    public func abandon() {
        try? handle.close()
        unlink(part)
        unlink(path.path)
    }
}
