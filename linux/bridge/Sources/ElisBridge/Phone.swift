import ElisCore
import Foundation

/// A `phone.*` request checked by the Mac's dispatcher: `{"ok":true,"op":"status|enable|port|host|revoke"}` with
/// `mode`, `port` or `host` (absent for `--auto`), else the Mac's refusal.
@_cdecl("elis_phone_request")
public func elisPhoneRequest(_ requestJSON: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Parsed: Encodable {
        var ok = true
        let op: String
        var mode: String?
        var port: Int?
        var host: String?
    }
    guard let request = try? JSONDecoder().decode(ControlRequest.self, from: Data(String(cString: requestJSON).utf8)) else {
        return encoded(Refusal(error: "invalid request"))
    }
    switch ControlDispatcher.phoneRequest(request) {
    case let .failure(rejection): return encoded(Refusal(error: rejection.message))
    case .success(.status): return encoded(Parsed(op: "status"))
    case let .success(.enable(mode)): return encoded(Parsed(op: "enable", mode: mode.rawValue))
    case let .success(.port(port)): return encoded(Parsed(op: "port", port: port))
    case let .success(.host(host)): return encoded(Parsed(op: "host", host: host))
    case .success(.revoke): return encoded(Parsed(op: "revoke"))
    }
}

/// The pairing link naming `host`, every other byte as serve printed it; a Bluetooth-only link gains `h` and `p`.
@_cdecl("elis_phone_link_with_host")
public func elisPhoneLinkWithHost(_ link: UnsafePointer<CChar>, _ host: UnsafePointer<CChar>, _ port: Int32)
    -> UnsafeMutablePointer<CChar>? {
    strdup(PhonePairLink.withHost(String(cString: link), host: String(cString: host), port: Int(port)))
}
