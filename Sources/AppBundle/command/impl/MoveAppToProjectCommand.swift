import AppKit
import Common

struct MoveAppToProjectCommand: Command {
    let args: MoveAppToProjectCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let projectNames = config.projects.map(\.name)
        if projectNames.isEmpty { return .fail(io.err("No projects are configured. Please declare [[projects]] in the config")) }
        if let name = args.project, !projectNames.contains(name) {
            return .fail(io.err("Unknown project '\(name)'. Configured projects: \(projectNames.joined(separator: ", "))"))
        }
        let pid: pid_t
        if let argPid = args.pid {
            pid = argPid
        } else {
            guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
            guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
            pid = window.app.pid
        }
        guard getRunningApps().contains(where: { $0.pid == pid }) else {
            return .fail(io.err("No running app with pid \(pid)"))
        }
        await moveAppToProject(pid: pid, project: args.project)
        return .succ
    }
}

/// R2.4. Manual ownership override. It's kept until the process exits
@MainActor func moveAppToProject(pid: pid_t, project: String?) async {
    setProjectOwnershipOverride(pid: pid, project: project)
    // Hide the process if the target project is inactive, unhide it if it was hidden by project switching
    await reapplyProjectVisibility()
    refocusIfFocusedWindowIsHidden()
    saveProjectState()
}
