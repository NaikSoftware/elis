import Foundation
import Testing
@testable import ElisCore

@MainActor
struct ControlDispatcherUploadTests {
    private func args(name: String? = "a.png", size: Int? = 5) -> ControlArgs {
        var args = ControlArgs(name: name, window: "w")
        args.size = size
        return args
    }

    private func dispatch(_ args: ControlArgs, actions: MockControlActions = MockControlActions()) async -> ControlResponse? {
        await ControlDispatcher(actions: actions).dispatch(ControlRequest(cmd: .sessionUpload, target: "s", args: args))
    }

    @Test func uploadRoutesToTheHost() async {
        let actions = MockControlActions()
        let response = await dispatch(args(), actions: actions)
        #expect(response?.ok == true)
        #expect(actions.calls == [.uploadDestination(target: "s", window: "w", name: "a.png", size: 5)])
    }

    @Test(arguments: [
        (UploadLimits.maxBytes + 1, "file too large (max 20 MiB)"),
        (-1, "upload needs a size"),
    ])
    func uploadRefusesABadSize(size: Int, error: String) async {
        let actions = MockControlActions()
        #expect(await dispatch(args(size: size), actions: actions)?.error == error)
        #expect(actions.calls.isEmpty)
    }

    @Test func uploadRefusesMissingArguments() {
        #expect(ControlDispatcher.uploadArguments(args(name: nil)).failure?.error == "upload needs a name")
        #expect(ControlDispatcher.uploadArguments(args(name: "")).failure?.error == "upload needs a name")
        #expect(ControlDispatcher.uploadArguments(args(size: nil)).failure?.error == "upload needs a size")
        #expect(ControlDispatcher.uploadArguments(args(size: UploadLimits.maxBytes)).failure == nil)
    }

    @Test func aPageSessionCannotUpload() {
        let request = ControlRequest(cmd: .sessionUpload, target: "s", args: args())
        #expect(PageSessionRefusal.refusal(request) { _, _ in true }?.error == "session.upload: not available on a page session")
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
