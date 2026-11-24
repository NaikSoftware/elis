import ElisCore
import Foundation

/// `session.upload` for a local row: the arguments' check, then a reserved path under `<stateDir>/uploads/<sessionID>/`.
@_cdecl("elis_upload_reserve")
public func elisUploadReserve(_ stateDir: UnsafePointer<CChar>, _ sessionID: UnsafePointer<CChar>,
                              _ argsJSON: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let text = String(cString: argsJSON)
    let args = text.isEmpty || text == "null" ? nil : try? JSONDecoder().decode(ControlArgs.self, from: Data(text.utf8))
    switch ControlDispatcher.uploadArguments(args) {
    case .failure(let refusal): return encoded(refusal)
    case .success(let upload):
        do {
            let url = try UploadStorage.reserve(stateDir: URL(fileURLWithPath: String(cString: stateDir)),
                                                sessionID: String(cString: sessionID), name: upload.name, now: Date())
            var result = ControlResult()
            result.upload = ControlUpload(path: url.path)
            return encoded(ControlResponse(ok: true, result: result))
        } catch {
            return encoded(ControlResponse(ok: false, error: "could not reserve an upload path: \(error.localizedDescription)"))
        }
    }
}

/// Removes upload folders no session in `keepJSON` (a JSON array of ids) owns, and files past the age cap;
/// `null` keeps every folder.
@_cdecl("elis_upload_sweep")
public func elisUploadSweep(_ stateDir: UnsafePointer<CChar>, _ keepJSON: UnsafePointer<CChar>) {
    let keep = (try? JSONDecoder().decode([String].self, from: Data(String(cString: keepJSON).utf8))).map(Set.init)
    UploadStorage.sweep(stateDir: URL(fileURLWithPath: String(cString: stateDir)), keep: keep, now: Date())
}
