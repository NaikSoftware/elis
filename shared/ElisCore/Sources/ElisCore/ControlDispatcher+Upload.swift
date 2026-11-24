extension ControlDispatcher {
    /// `session.upload`'s arguments, validated the same way on every host; public for `linux/bridge`.
    nonisolated public static func uploadArguments(_ args: ControlArgs?) -> Result<(name: String, size: Int), ControlResponse> {
        guard let name = args?.name, !name.isEmpty else { return .failure(ControlResponse(ok: false, error: "upload needs a name")) }
        guard let size = args?.size, size >= 0 else { return .failure(ControlResponse(ok: false, error: "upload needs a size")) }
        guard size <= UploadLimits.maxBytes else { return .failure(ControlResponse(ok: false, error: "file too large (max 20 MiB)")) }
        return .success((name, size))
    }

    func dispatchSessionUpload(_ request: ControlRequest) -> ControlResponse {
        switch Self.uploadArguments(request.args) {
        case .failure(let refusal): return refusal
        case .success(let upload):
            return actions.uploadDestination(request.target, window: request.args?.window, name: upload.name, size: upload.size)
        }
    }
}
