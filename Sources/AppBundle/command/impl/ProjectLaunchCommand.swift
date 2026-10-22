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
            // Apps that the active project doesn't reference target their global instances, as if no project was active.
            // An explicit --project keeps failing for them
            let globalAppIds = args.project == nil ? args.appIds.filter { appId in !project.apps.contains { $0.appId == appId } } : []
            let projectAppIds = args.appIds.filter { !globalAppIds.contains($0) }
            plan = globalAppIds.isEmpty
                ? getProjectLaunchPlan(project, appIds: args.appIds, open: args.open, getRunningApps(), home: homeDirPath)
                : getGlobalAppLaunchPlan(appIds: globalAppIds, open: args.open, getRunningApps(), home: homeDirPath).flatMap { globalSteps in
                    projectAppIds.isEmpty
                        ? .success(globalSteps)
                        : getProjectLaunchPlan(project, appIds: projectAppIds, open: args.open, getRunningApps(), home: homeDirPath)
                            .map { $0 + globalSteps }
                }
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
