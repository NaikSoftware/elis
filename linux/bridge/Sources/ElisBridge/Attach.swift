import ElisCore
import Foundation
import Synchronization

// session.attach for the phone relay, and the relay's stderr lines, as the Mac's ControlServer+Attach and PhoneRelay read them.

private func object(_ json: UnsafePointer<CChar>) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(String(cString: json).utf8))) as? [String: Any] ?? [:]
}

private func returned(_ value: Any) -> UnsafeMutablePointer<CChar>? {
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
    return strdup(String(decoding: data, as: UTF8.self))
}

/// `{"stateDir","buildID"}` -> `{"cutoff": seconds}`, or `{}` without a build id: when this state directory first ran
/// this zmx build, recorded in its `zmx-build.json` as on the Mac.
@_cdecl("elis_zmx_build_cutoff")
public func elisZmxBuildCutoff(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let args = object(json)
    let directory = URL(fileURLWithPath: args["stateDir"] as? String ?? "", isDirectory: true)
    guard let cutoff = ZmxBuildRecord.launchCutoff(bundledID: args["buildID"] as? String, directory: directory) else {
        return returned([String: Any]())
    }
    return returned(["cutoff": cutoff.timeIntervalSince1970])
}

/// A Live pane's phone attach: `{"zmx","stateDir","runtimeDir","pane","claim","list"?,"cutoff"?}` ->
/// `{"attach": {argv, paneID, screen, remote, nonce?}}`, `{"outdated": true}` for a daemon `list` dates before `cutoff`,
/// or `{"invalid": true}` when no attach can be built. A missing listing or created time serves the attach.
@_cdecl("elis_session_attach")
public func elisSessionAttach(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let args = object(json)
    guard let token = args["pane"] as? String, let identity = UUID(uuidString: token) else { return returned(["invalid": true]) }
    let state = args["stateDir"] as? String ?? ""
    let runtime = args["runtimeDir"] as? String ?? ""
    let directory = runtime.isEmpty ? ZmxSupport.socketDirectory(forStateDirectory: state)
        : ZmxSupport.socketDirectory(forStateDirectory: state, runtimeDirectory: runtime)
    let daemon = ZmxSupport.daemonName(for: identity)
    if let cutoff = args["cutoff"] as? Double, let list = args["list"] as? String,
       let records = try? ZmxListParser.parse(list),
       LiveReset.isOutdated(created: records.first { $0.name == daemon }?.createdAt, cutoff: Date(timeIntervalSince1970: cutoff)) {
        return returned(["outdated": true])
    }
    let source = LivePaneSource.local(endpoint: ControlZmxEndpoint(executable: args["zmx"] as? String ?? "", socketDirectory: directory),
                                      daemon: daemon)
    // the pane's token is its identity on Linux; Linux has no presentation hub, so no origin
    guard let attach = try? (args["claim"] as? Bool == true ? ControlAttach.claimer(source, paneID: token) : ControlAttach.viewer(source, paneID: token)),
          let data = try? JSONEncoder().encode(attach), let encoded = try? JSONSerialization.jsonObject(with: data) else {
        return returned(["invalid": true])
    }
    return returned(["attach": encoded])
}

/// The phone's open panes and the panes it leads, counted from the relay's lines; read into tree `surfaces[]`.
let phone = Mutex((viewers: PhoneViewers(), leads: PhoneViewers()))

private func count(_ viewers: inout PhoneViewers, opened: Bool, paneID: String) -> Bool {
    guard opened else { return viewers.detach(paneID: paneID) }
    viewers.attach(paneID: paneID)
    return true
}

/// One `elisctl mobile serve` stderr line -> `{"kind": "event"|"other"|"bluetooth"|"viewer"|"lead", ...}`, `{}` for a
/// blank one: an event's `text`, and its `event` and `ip` when it is a control event. A viewer (`attached`) or lead
/// (`leading`) line, with `paneID` and `ip` (absent for the relay's `-`), is counted; `emit` is false for the end of one
/// never counted.
@_cdecl("elis_phone_relay_line")
public func elisPhoneRelayLine(_ line: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    var out: [String: Any] = [:]
    switch PhoneRelayLine.stderr(String(cString: line)) {
    case nil: break
    case .event(let text):
        out = ["kind": "event", "text": text]
        if let event = PhoneRelayLine.controlEvent(text) { out["event"] = event.kind.rawValue; out["ip"] = event.ip }
    case .other(let text): out = ["kind": "other", "text": text]
    case .bluetooth(let value): out = ["kind": "bluetooth", "value": value]
    case let .viewer(attached, ip, paneID):
        let emit = phone.withLock { counts in count(&counts.viewers, opened: attached, paneID: paneID) }
        out = ["kind": "viewer", "attached": attached, "paneID": paneID, "emit": emit]
        if let ip = PhoneRelayLine.address(ip) { out["ip"] = ip }
    case let .lead(leading, ip, paneID):
        let emit = phone.withLock { counts in count(&counts.leads, opened: leading, paneID: paneID) }
        out = ["kind": "lead", "leading": leading, "paneID": paneID, "emit": emit]
        if let ip = PhoneRelayLine.address(ip) { out["ip"] = ip }
    }
    return returned(out)
}

/// A relay that stopped: every count cleared, `{"detached":[paneID],"released":[paneID]}` one per viewer and lead it held.
@_cdecl("elis_phone_viewers_reset")
public func elisPhoneViewersReset() -> UnsafeMutablePointer<CChar>? {
    let (detached, released) = phone.withLock { ($0.viewers.reset(), $0.leads.reset()) }
    return returned(["detached": detached, "released": released])
}

/// `{"viewers": count, "lead": bool}` for a pane token.
@_cdecl("elis_phone_viewers")
public func elisPhoneViewers(_ paneID: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let token = String(cString: paneID)
    let (viewers, lead) = phone.withLock { ($0.viewers.count(paneID: token), $0.leads.count(paneID: token) > 0) }
    return returned(["viewers": viewers, "lead": lead])
}
