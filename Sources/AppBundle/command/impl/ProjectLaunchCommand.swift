import AppKit
import Common

struct ProjectLaunchCommand: Command {
    let args: ProjectLaunchCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        if config.projects.isEmpty && config.projectApps.isEmpty {
            return .fail(io.err("No projects are configured. Please declare [[projects]] in the config"))
        }
        let plan: Result<[ProjectLaunchStep], String>
        if let name = args.project ?? activeProjectName {
            guard let project = config.projects.first(where: { $0.name == name }) else {
                return .fail(io.err("Unknown project '\(name)'. Configured projects: \(config.projects.map(\.name).joined(separator: ", "))"))
            }
            plan = getProjectLaunchPlan(project, appIds: args.appIds, open: args.open, getRunningApps(), home: homeDirPath)
        } else {
            if args.appIds.isEmpty {
                return .fail(io.err("No project is active. Please specify --project or --app"))
            }
            plan = getGlobalAppLaunchPlan(appIds: args.appIds, open: args.open, getRunningApps(), home: homeDirPath)
        }
        return switch plan {
            case .success(let steps): await executeProjectLaunchPlan(steps, io)
            case .failure(let msg): .fail(io.err(msg))
        }
    }
}
