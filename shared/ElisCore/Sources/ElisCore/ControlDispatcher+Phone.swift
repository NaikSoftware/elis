import Foundation

/// A `phone.*` request as the dispatcher checked it.
public enum PhoneRequest: Equatable, Sendable {
    case status
    case enable(ControlToggleMode)
    case port(Int)
    /// nil: follow the relay's best address.
    case host(String?)
    case revoke
}

public struct PhoneRejection: Error, Equatable {
    public let message: String
}

extension ControlDispatcher {
    func dispatchPhoneCommand(_ request: ControlRequest) async -> ControlResponse {
        switch Self.phoneRequest(request) {
        case let .failure(rejection): return ControlResponse(ok: false, error: rejection.message)
        case .success(.status): return actions.phoneStatus()
        case let .success(.enable(mode)): return await actions.setPhoneEnabled(mode)
        case let .success(.port(port)): return await actions.setPhonePort(port)
        case let .success(.host(host)): return actions.setPhoneHost(host)
        case .success(.revoke): return await actions.revokePhone()
        }
    }

    /// `phone.*` drive the app's one phone relay, so a target or `--window` is refused like `hooks.*`.
    public nonisolated static func phoneRequest(_ request: ControlRequest) -> Result<PhoneRequest, PhoneRejection> {
        let refuse = { (message: String) in Result<PhoneRequest, PhoneRejection>.failure(PhoneRejection(message: message)) }
        if request.target != nil || request.args?.window != nil {
            return refuse("\(request.cmd.rawValue) takes no target or --window")
        }
        let args = request.args
        switch request.cmd {
        case .phoneStatus:
            return .success(.status)
        case .phoneEnable:
            guard let mode = ControlToggleMode.parse(args?.mode) else { return refuse("phone.enable requires on|off|toggle") }
            return .success(.enable(mode))
        case .phonePort:
            guard let port = args?.port, PhoneDesktopState.portRange.contains(port) else { return refuse(PhoneDesktopState.portError) }
            return .success(.port(port))
        case .phoneHost:
            let auto = args?.auto == true
            guard auto != (args?.host != nil), args?.auto != false else { return refuse("phone.host takes a host or auto") }
            if auto { return .success(.host(nil)) }
            let host = args?.host?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !host.isEmpty, host.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.controlCharacters.contains($0) }) else {
                return refuse("phone.host requires a host without spaces or control characters")
            }
            return .success(.host(host))
        case .phoneRevoke:
            return .success(.revoke)
        default:
            return refuse("\(request.cmd.rawValue) is not a phone command")
        }
    }
}
