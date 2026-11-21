import ElisCore
import Foundation
import Synchronization
#if canImport(Glibc)
import Glibc
#endif

// Live panes on zmx: naming, the attach line, `zmx list`, the launch reap and the lead state, all ElisCore's.

private func object(_ json: UnsafePointer<CChar>) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(String(cString: json).utf8))) as? [String: Any] ?? [:]
}

private func returned(_ value: Any) -> UnsafeMutablePointer<CChar>? {
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
    return strdup(String(decoding: data, as: UTF8.self))
}

private func pane(_ text: Any?) -> UUID? { (text as? String).flatMap(UUID.init(uuidString:)) }

private func socketDirectory(_ args: [String: Any]) -> String {
    let state = args["stateDir"] as? String ?? ""
    guard let runtime = args["runtimeDir"] as? String, !runtime.isEmpty else {
        return ZmxSupport.socketDirectory(forStateDirectory: state)
    }
    return ZmxSupport.socketDirectory(forStateDirectory: state, runtimeDirectory: runtime)
}

/// Every pane's lead state, keyed by pane identity; the Qt app calls from its GUI thread, the lock keeps it honest.
private let leads = Mutex<[UUID: ZmxLeadState]>([:])

private func leadReport(_ state: ZmxLeadState?) -> [String: Any] {
    var out: [String: Any] = ["covered": state?.covered ?? false, "reattaching": state?.reattaching ?? false]
    if let role = state?.role { out["role"] = role.rawValue }
    return out
}

/// `{"stateDir","runtimeDir","panes":[id]}` -> `{"socketDir","names":[daemon],"env"}`, an invalid id naming nothing;
/// `env` is what every zmx command of that namespace sets.
@_cdecl("elis_zmx_names")
public func elisZmxNames(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let args = object(json)
    let names = (args["panes"] as? [Any] ?? []).compactMap { pane($0).map(ZmxSupport.daemonName(for:)) }
    let directory = socketDirectory(args)
    return returned(["socketDir": directory, "names": names, "env": ZmxSupport.clientEnvironment(socketDirectory: directory)])
}

/// A pane's attach: `{"zmx","stateDir","runtimeDir","pane","shell","line"?,"command"?,"claim","reattaching"}` ->
/// `{"daemon","socketDir","argv","set","unset"}`, or `{"error"}`. `line` (a captured command, a pin, a resume line)
/// runs and returns to the login shell, `command` ends the pane; either only when the attach creates the daemon.
/// It begins the pane's lead state, so reports of its previous attachment no longer match.
@_cdecl("elis_zmx_attach")
public func elisZmxAttach(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let args = object(json)
    guard let identity = pane(args["pane"]), let zmx = args["zmx"] as? String, zmx.hasPrefix("/") else {
        return returned(["error": "a zmx attach needs an absolute zmx path and a pane identity"])
    }
    let shell = args["shell"] as? String ?? "/bin/sh"
    let directory = socketDirectory(args)
    let daemon = ZmxSupport.daemonName(for: identity)
    var payload: [String] = []
    if let command = args["command"] as? String, !command.isEmpty {
        payload = [shell, "-c", command]
    } else if let line = args["line"] as? String, !line.isEmpty {
        payload = ZmxReplayScript.plainShellArguments(commandLine: line, shell: shell)
    }
    let lead = ZmxLeadAttachment(claim: args["claim"] as? Bool ?? false)
    leads.withLock { $0[identity] = ZmxLeadState(attachment: lead, reattaching: args["reattaching"] as? Bool ?? false) }
    var set = ZmxSupport.clientEnvironment(socketDirectory: directory).merging(lead.environment) { _, new in new }
    set["SHELL"] = shell
    let unset = [ZmxLeadAttachment.nonceVariable, ZmxLeadAttachment.claimVariable, ZmxLeadAttachment.screenOnlyVariable,
                 ZmxLeadAttachment.followVariable].filter { set[$0] == nil }
    return returned(["daemon": daemon, "socketDir": directory, "argv": [zmx, "attach", daemon] + payload,
                     "set": set, "unset": unset])
}

/// `zmx list`'s stdout -> `{"ok":true,"sessions":[{"name","clients"?,"pid"?}]}`, or `{"ok":false,"error"}` for a
/// listing no decision may rest on.
@_cdecl("elis_zmx_list")
public func elisZmxList(_ output: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    do {
        let sessions = try ZmxListParser.parse(String(cString: output)).map { record -> [String: Any] in
            var row: [String: Any] = ["name": record.name]
            if let clients = record.clients { row["clients"] = clients }
            if let pid = record.leaderPID { row["pid"] = Int(pid) }
            return row
        }
        return returned(["ok": true, "sessions": sessions])
    } catch {
        return returned(["ok": false, "error": "zmx list: \(error)"])
    }
}

/// The launch reap: `{"list": zmx list stdout, "mode": the requested restore mode, "known": [pane ids] | null}` ->
/// `{"kill":[names]}`, or `{"kill":null}` when the listing or a requested-live inventory is incomplete.
@_cdecl("elis_zmx_reap")
public func elisZmxReap(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let args = object(json)
    let mode = RestoreMode(rawValue: args["mode"] as? String ?? "") ?? .none
    let known = (args["known"] as? [Any]).map { Set($0.compactMap { pane($0).map(ZmxSupport.daemonName(for:)) }) }
    guard let sessions = try? ZmxListParser.parse(args["list"] as? String ?? ""),
          let names = ZmxReapPolicy.namesToKill(sessions: sessions, requestedMode: mode, knownNames: known) else {
        return returned(["kill": NSNull()])
    }
    return returned(["kill": names])
}

/// A pane's terminal title: `{"pane","title"}` -> `{"report":false}` for any other title, else
/// `{"report":true,"changed",...}` with the state `elis_zmx_lead_state` returns.
@_cdecl("elis_zmx_lead_report")
public func elisZmxLeadReport(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let args = object(json)
    guard let notice = ZmxLeadNotice(title: args["title"] as? String ?? "") else { return returned(["report": false]) }
    guard let identity = pane(args["pane"]) else { return returned(["report": true, "changed": false]) }
    let (changed, state) = leads.withLock { states -> (Bool, ZmxLeadState?) in
        guard var state = states[identity] else { return (false, nil) }
        let changed = state.apply(notice)
        states[identity] = state
        return (changed, state)
    }
    return returned(leadReport(state).merging(["report": true, "changed": changed]) { _, new in new })
}

/// `{"role"?,"covered","reattaching"}` for a pane identity; nothing known reads uncovered.
@_cdecl("elis_zmx_lead_state")
public func elisZmxLeadState(_ identity: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let state = pane(String(cString: identity)).flatMap { id in leads.withLock { $0[id] } }
    return returned(leadReport(state))
}

@_cdecl("elis_zmx_lead_forget")
public func elisZmxLeadForget(_ identity: UnsafePointer<CChar>) {
    if let id = pane(String(cString: identity)) { _ = leads.withLock { $0.removeValue(forKey: id) } }
}

/// `session.type`'s text as `zmx type` input: `{"head": base64 bytes, "pacedReturn", "gapMs"}`; a paced final Return
/// goes as its own call after `KeystrokeSegments.submitGap`.
@_cdecl("elis_zmx_type_bytes")
public func elisZmxTypeBytes(_ text: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let paced = KeystrokeSegments.paced(String(cString: text))
    return returned(["head": Data(KeystrokeSegments.ptyBytes(paced.head)).base64EncodedString(), "pacedReturn": paced.pacedReturn,
                     "gapMs": Int(KeystrokeSegments.submitGap * 1000)])
}

/// `zmx screen`'s stdout and a line count -> `{"ok":true,"text","columns","rows"}`, `{"ok":false}` for anything else.
@_cdecl("elis_zmx_screen")
public func elisZmxScreen(_ output: UnsafePointer<CChar>, _ lines: Int32) -> UnsafeMutablePointer<CChar>? {
    guard let screen = ZmxScreen(output: String(cString: output)) else { return returned(["ok": false]) }
    return returned(["ok": true, "text": lines > 0 ? screen.lastLines(Int(lines)) : screen.text, "columns": screen.columns,
                     "rows": screen.rows])
}

/// One tree `surfaces[]` entry, as the Mac encodes it: `{"id","kind","active","visible","backedByZmx","paneID"?}`
/// in, with `lead` read from the pane's state.
@_cdecl("elis_zmx_surface")
public func elisZmxSurface(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let args = object(json)
    let token = args["paneID"] as? String
    let lead = pane(token).flatMap { id in leads.withLock { $0[id]?.role } }
    let node = ControlSurfaceNode(id: args["id"] as? String ?? "", kind: args["kind"] as? String ?? "",
                                  active: args["active"] as? Bool ?? false, visible: args["visible"] as? Bool ?? false,
                                  backedByZmx: args["backedByZmx"] as? Bool, lead: lead,
                                  paneID: token?.isEmpty == false ? token : nil)
    let data = (try? JSONEncoder().encode(node)) ?? Data("{}".utf8)
    return strdup(String(decoding: data, as: UTF8.self))
}
