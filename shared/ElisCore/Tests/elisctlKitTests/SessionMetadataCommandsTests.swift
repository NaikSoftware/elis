import ArgumentParser
import Testing
import ElisCore
@testable import elisctlKit

@Suite(.outsidePane)
struct SessionMetadataCommandsTests {
    private func request(_ argv: [String]) throws -> ControlRequest {
        let parsed = try Elisctl.parseAsRoot(argv)
        guard let command = parsed as? any RequestCommand else {
            throw SocketClientError("parsed \(argv) is not a RequestCommand")
        }
        return try command.makeRequest()
    }

    @Test func flagMoveCarriesTheTargetAndBeforeAnchor() throws {
        var args = ControlArgs(mode: "move", window: "w1")
        args.before = "bb"
        #expect(try request(["session", "flag", "move", "--target", "aa", "--before", "bb", "--window", "w1"])
            == ControlRequest(cmd: .sessionFlag, target: "aa", args: args))
    }

    @Test func flagMoveCarriesTheAfterAnchor() throws {
        var args = ControlArgs(mode: "move")
        args.after = "cc"
        #expect(try request(["session", "flag", "move", "--after", "cc"])
            == ControlRequest(cmd: .sessionFlag, target: "active", args: args))
    }

    @Test(arguments: [["session", "flag", "move"], ["session", "flag", "move", "--before", "b", "--after", "c"]])
    func flagMoveNeedsExactlyOneAnchor(_ argv: [String]) {
        #expect(throws: (any Error).self) { try Elisctl.parseAsRoot(argv) }
    }

    @Test(arguments: ["on", "toggle", "clear"])
    func flagRefusesAnAnchorOutsideMove(_ mode: String) {
        #expect(throws: (any Error).self) { try Elisctl.parseAsRoot(["session", "flag", mode, "--after", "c"]) }
    }

    private func validationMessage(_ argv: [String]) -> String? {
        do {
            _ = try Elisctl.parseAsRoot(argv)
            return nil
        } catch {
            return Elisctl.message(for: error)
        }
    }

    @Test func flagKeepsItsExistingModesAndTheToggleDefault() throws {
        #expect(try request(["session", "flag"])
            == ControlRequest(cmd: .sessionFlag, target: "active", args: ControlArgs(mode: "toggle")))
        #expect(try request(["session", "flag", "off", "--target", "aa"])
            == ControlRequest(cmd: .sessionFlag, target: "aa", args: ControlArgs(mode: "off")))
    }

    @Test(arguments: [(ControlRestoreOverride.pin("-x --resume"), "set", "-x --resume" as String?), (.pinNone, "none", nil), (.unpin, "clear", nil)])
    func anAttachedRestoreParsesOnItsOrigin(pin: ControlRestoreOverride, mode: String, command: String?) throws {
        let forward = AttachedForward.restore(session: "s1", paneID: "tok", pin: pin)

        let parsed = try request(forward.originArgv)

        #expect(parsed == ControlRequest(cmd: .sessionRestore, target: "s1", args: ControlArgs(mode: mode, command: command, paneID: "tok")))
        #expect(parsed.cmd == forward.command)
    }
}
