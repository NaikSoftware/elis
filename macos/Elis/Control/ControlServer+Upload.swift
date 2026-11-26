import ElisCore
import Foundation

extension ControlServer {
    func uploadDestination(_ target: String?, window: String?, name: String, size _: Int) -> ControlResponse {
        switch resolver.resolveSessionTarget(target, window: window) {
        case .failure(let refusal):
            return refusal
        case .success(let (store, id)):
            guard let session = store.session(withID: id) else { return ControlResponse(ok: false, error: "session not found") }
            return UploadStorage.answer(for: session, stateDir: library.directory, name: name, now: Date())
        }
    }
}
