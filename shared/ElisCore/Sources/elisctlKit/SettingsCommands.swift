import ArgumentParser
import ElisCore

struct SettingsGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "settings",
        abstract: "App-wide settings without a command group of their own.",
        subcommands: [KeepAwake.self]
    )

    /// `elisctl settings keep-awake [on|off|toggle]`; app-wide, so no `--window`.
    struct KeepAwake: RequestCommand {
        static let configuration = CommandConfiguration(
            commandName: "keep-awake",
            abstract: "Keep the computer from idle sleep while an agent is working (on|off|toggle).",
            discussion: "On (the default), the computer does not sleep on its own while any session's status is active; "
                + "the display still sleeps and locks. Prints the new setting; tree's keepAwake reads it."
        )
        @Argument(help: "Mode: on, off, or toggle (default).") var mode: String = "toggle"
        @OptionGroup var options: BasicOptions

        func validate() throws {
            guard ControlToggleMode.parse(mode) != nil else { throw ValidationError("mode must be on, off, or toggle") }
        }

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .settingsKeepAwake, args: ControlArgs(mode: mode)) }
    }
}
