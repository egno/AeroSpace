import AppKit
import Common

struct ProjectQuitCommand: Command {
    let args: ProjectQuitCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        let projectNames = config.projects.map(\.name)
        if projectNames.isEmpty { return .fail(io.err("No projects are configured. Please declare [[projects]] in the config")) }
        guard let name = args.project ?? activeProjectName else {
            return .fail(io.err("No project is active. Please specify <project-name>"))
        }
        guard projectNames.contains(name) else {
            return .fail(io.err("Unknown project '\(name)'. Configured projects: \(projectNames.joined(separator: ", "))"))
        }
        // The active project stays active. Its windows just go away
        var result: BinaryExitCode = .succ
        for pid in getProjectQuitTargets(name, getRunningApps()) where !terminateProcess(pid) {
            result = .fail(io.err("Failed to quit process \(pid)"))
        }
        return result
    }
}
