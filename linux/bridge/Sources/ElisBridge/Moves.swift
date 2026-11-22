import ElisCore
import Foundation

private struct Move: Encodable {
    var ok = true
    var to: String?
    var workspace: String?
    var anchor: String?
    var after: Bool?
}

/// `session.move`'s placement intent by the Mac's parse: `{"ok":true}` with `to`, `workspace`, or `anchor` and `after`,
/// else the refusal. Input: the request's `to`, `workspace`, `after`, `before` and `targets`.
@_cdecl("elis_session_move_arguments")
public func elisSessionMoveArguments(_ argsJSON: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    guard let args = try? JSONDecoder().decode(ControlArgs.self, from: Data(String(cString: argsJSON).utf8)) else {
        return encoded(Refusal(error: "invalid arguments"))
    }
    switch ControlDispatcher.sessionMoveArguments(args) {
    case .failure(let refusal): return encoded(refusal)
    case .success(.reorder(let direction)): return encoded(Move(to: direction.rawValue))
    case .success(.workspace(let workspace)): return encoded(Move(workspace: workspace))
    case .success(.place(let anchor, let after)): return encoded(Move(anchor: anchor, after: after))
    }
}

/// Where `session.move --after/--before` lands, by the Mac's drop math: `SidebarDrop.resolveRelative` for one source,
/// `resolveSessions` for a batch. Input `{"sources":[{"workspace","index"}],"anchor":{"workspace","index","count"},"after"}`
/// with workspaces as indices. `{"ok":true,"workspace","destination"}`, the destination counted with the moving rows
/// removed, or `{"ok":true}` when the move changes nothing.
@_cdecl("elis_session_placement")
public func elisSessionPlacement(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Place: Decodable {
        let workspace: Int
        let index: Int
        let count: Int?
    }
    struct Input: Decodable {
        let sources: [Place]
        let anchor: Place
        let after: Bool
    }
    struct Landing: Encodable {
        var ok = true
        let workspace: Int?
        let destination: Int?
    }
    guard let input = try? JSONDecoder().decode(Input.self, from: Data(String(cString: json).utf8)), !input.sources.isEmpty else {
        return encoded(Refusal(error: "invalid arguments"))
    }
    let id = { (index: Int) in
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(truncatingIfNeeded: index >> 8), UInt8(truncatingIfNeeded: index)))
    }
    let anchor = input.anchor
    let resolution: SidebarDrop.SessionResolution?
    if input.sources.count == 1, let source = input.sources.first {
        resolution = SidebarDrop.resolveRelative(source: (workspace: id(source.workspace), index: source.index),
                                                 anchor: (workspace: id(anchor.workspace), index: anchor.index, count: anchor.count ?? 0),
                                                 placeAfter: input.after)
    } else {
        let target = SidebarDrop.SessionDropTarget.sessionRow(workspace: id(anchor.workspace), sessionIndex: anchor.index,
                                                              sessionCount: anchor.count ?? 0)
        resolution = SidebarDrop.resolveSessions(sources: input.sources.map { SidebarDrop.SessionSource(workspace: id($0.workspace), index: $0.index) },
                                                 target: target, childIndex: input.after ? SidebarDrop.onItemIndex : anchor.index)
    }
    guard let resolution else { return encoded(Landing(workspace: nil, destination: nil)) }
    // the anchor's row names the destination workspace
    return encoded(Landing(workspace: anchor.workspace, destination: resolution.destination))
}

/// A `--to up|down|top|bottom` step from `index` among `count` rows (`ReorderDirection`): `{"ok":true,"destination"}`,
/// the destination absent at that end. Input `{"to","index","count"}`.
@_cdecl("elis_reorder_destination")
public func elisReorderDestination(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Input: Decodable {
        let to: String
        let index: Int
        let count: Int
    }
    struct Step: Encodable {
        var ok = true
        let destination: Int?
    }
    guard let input = try? JSONDecoder().decode(Input.self, from: Data(String(cString: json).utf8)),
          let direction = ReorderDirection(rawValue: input.to) else {
        return encoded(Refusal(error: "invalid arguments"))
    }
    return encoded(Step(destination: direction.destinationIndex(from: input.index, count: input.count)))
}

/// A project folder by the Mac's check: `{"ok":true,"folder"}` normalized, or the refusal. Whether it exists is the
/// host's to check.
@_cdecl("elis_project_folder")
public func elisProjectFolder(_ path: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Folder: Encodable {
        var ok = true
        let folder: String
    }
    switch Workspace.validatedProjectFolder(String(cString: path)) {
    case .failure(let rejection): return encoded(Refusal(error: rejection.message))
    case .success(let folder): return encoded(Folder(folder: folder))
    }
}
