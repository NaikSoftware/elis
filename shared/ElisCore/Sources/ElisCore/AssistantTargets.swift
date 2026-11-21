public struct AssistantPeer: Codable, Sendable, Equatable {
    public var sessionID: String
    public var window: String
    public var workspaceID: String
    public var workspaceName: String
    public var name: String
    public var agent: String?
    public var status: String?

    public init(sessionID: String, window: String, workspaceID: String, workspaceName: String,
                name: String, agent: String? = nil, status: String? = nil) {
        self.sessionID = sessionID
        self.window = window
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.name = name
        self.agent = agent
        self.status = status
    }
}

public struct AssistantDirectory: Sendable {
    public let peers: [AssistantPeer]
    private let sessionHandles: [String: String]
    private let workspaceHandles: [String: String]

    public init(_ peers: [AssistantPeer]) {
        self.peers = peers
        sessionHandles = AssistantHandle.assign(peers.map { (id: $0.sessionID, name: $0.name) })
        var seen = Set<String>()
        let workspaces = peers.filter { seen.insert($0.workspaceID).inserted }
        workspaceHandles = AssistantHandle.assign(workspaces.map { (id: $0.workspaceID, name: $0.workspaceName) })
    }

    public func handle(of sessionID: String) -> String? { sessionHandles[sessionID] }
    public func workspaceHandle(of workspaceID: String) -> String? { workspaceHandles[workspaceID] }
}

public struct AssistantSkip: Codable, Sendable, Equatable {
    public var handle: String
    public var reason: String

    public init(handle: String, reason: String) {
        self.handle = handle
        self.reason = reason
    }
}

public struct AssistantDelivery: Sendable, Equatable {
    public var targets: [AssistantPeer]
    public var skipped: [AssistantSkip]
}

public enum AssistantTagError: Error, Equatable, Sendable {
    case unknown(String)
    case noTags

    public var message: String {
        switch self {
        case .unknown(let tag): "unknown tag @\(tag)"
        case .noTags: "no tags"
        }
    }
}

public enum AssistantTargets {
    /// resolve matches tags case-insensitively; a tag is a handle, `ws:<handle>`, `all`, or an exact session id.
    public static func resolve(_ tags: [String], in directory: AssistantDirectory) throws(AssistantTagError) -> AssistantDelivery {
        if tags.isEmpty { throw .noTags }
        var seen = Set<String>()
        var delivery = AssistantDelivery(targets: [], skipped: [])
        for raw in tags {
            let typed = raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
            let tag = typed.lowercased()
            let chosen: [AssistantPeer]
            if tag == "all" {
                chosen = directory.peers.filter { $0.agent != nil }
            } else if tag.hasPrefix("ws:") {
                let handle = String(tag.dropFirst(3))
                let inWorkspace = directory.peers.filter { directory.workspaceHandle(of: $0.workspaceID) == handle }
                if inWorkspace.isEmpty { throw .unknown(typed) }
                chosen = inWorkspace.filter { $0.agent != nil }
            } else if let peer = directory.peers.first(where: { directory.handle(of: $0.sessionID) == tag })
                        ?? directory.peers.first(where: { $0.sessionID.lowercased() == tag }) {
                chosen = [peer]
            } else {
                throw .unknown(typed)
            }
            for peer in chosen where seen.insert(peer.sessionID).inserted {
                if peer.status == "blocked" {
                    delivery.skipped.append(AssistantSkip(handle: directory.handle(of: peer.sessionID) ?? peer.sessionID, reason: "blocked"))
                } else {
                    delivery.targets.append(peer)
                }
            }
        }
        return delivery
    }
}

public enum AssistantLineError: Error, Equatable, Sendable {
    case nul
    case empty

    public var message: String {
        switch self {
        case .nul: "text must not contain a NUL byte"
        case .empty: "empty message"
        }
    }
}

public enum AssistantLine {
    public static let maxBytes = 900
    private static let prefix = "[Elis] "
    private static let hint = " — reply: elisctl reply \"<answer>\""

    /// fold turns each run of whitespace and control characters into one space and trims both ends.
    public static func fold(_ text: String) -> String {
        var folded = ""
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if scalar.properties.generalCategory == .control || scalar.properties.isWhitespace {
                pendingSpace = true
            } else {
                if pendingSpace && !folded.isEmpty { folded.append(" ") }
                pendingSpace = false
                folded.unicodeScalars.append(scalar)
            }
        }
        return folded
    }

    public static func make(_ text: String) throws(AssistantLineError) -> String {
        if text.unicodeScalars.contains(where: { $0.value == 0 }) { throw .nul }
        let folded = fold(text)
        if folded.isEmpty { throw .empty }
        var budget = maxBytes - prefix.utf8.count - hint.utf8.count
        var body = ""
        for ch in folded {
            budget -= String(ch).utf8.count
            if budget < 0 { break }
            body.append(ch)
        }
        while body.hasSuffix(" ") { body.removeLast() }
        return prefix + body + hint
    }
}
