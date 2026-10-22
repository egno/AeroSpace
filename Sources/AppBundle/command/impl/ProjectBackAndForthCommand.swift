import AppKit
import Common

struct ProjectBackAndForthCommand: Command {
    let args: ProjectBackAndForthCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let prev = prevActiveProjectName else {
            return .fail(io.err("No previously active project"))
        }
        await switchProject(to: prev)
        return .succ
    }
}
