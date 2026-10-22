import AppKit
import Common

struct MoveWindowToProjectCommand: Command {
    let args: MoveWindowToProjectCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let projectNames = config.projects.map(\.name)
        if projectNames.isEmpty { return .fail(io.err("No projects are configured. Please declare [[projects]] in the config")) }
        if let name = args.project, !projectNames.contains(name) {
            return .fail(io.err("Unknown project '\(name)'. Configured projects: \(projectNames.joined(separator: ", "))"))
        }
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        if !isPerWindowProcess(window.app) {
            return .fail(io.err(
                "Window \(window.windowId) doesn't belong to a per-window app ([project-apps.<id>] with 'window-if'). " +
                    "Use move-app-to-project to move the whole process",
            ))
        }
        await moveWindowToProject(window, project: args.project)
        return .succ
    }
}
