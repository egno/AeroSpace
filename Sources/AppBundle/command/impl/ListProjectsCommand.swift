import AppKit
import Common

struct ListProjectsCommand: Command {
    let args: ListProjectsCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        var result = getProjectInfos(apps: Array(MacApp.allAppsMap.values))
        if args.onlyActive {
            result = result.filter(\.isActive)
        }

        lazy var list = result.map(AeroObj.project)
        return switch true {
            case args.outputOnlyCount:
                .succ(io.out("\(result.count)"))
            case args.json:
                switch list.formatToJson(args.format, ignoreRightPaddingVar: args._format.isEmpty) {
                    case .success(let json): .succ(io.out(json))
                    case .failure(let msg): .fail(io.err(msg))
                }
            default:
                switch list.format(args.format) {
                    case .success(let lines): .succ(io.out(lines))
                    case .failure(let msg): .fail(io.err(msg.map(\.description).joinErrors()))
                }
        }
    }
}

struct ProjectInfo {
    let name: String
    let isActive: Bool
    let appIds: [String]
    let runningAppIds: [String]
}

@MainActor func getProjectInfos(apps: [any AbstractApp]) -> [ProjectInfo] {
    config.projects.map { project in
        let projectProcesses = apps.filter { getProjectName(of: $0) == project.name }
        return ProjectInfo(
            name: project.name,
            isActive: project.name == activeProjectName,
            appIds: project.apps.map(\.appId),
            runningAppIds: project.apps
                .filter { projectApp in
                    // A per-window app is running for the project if the project owns at least one of its windows
                    projectApp.isPerWindow
                        ? !getProjectAppWindows(projectApp, project: project.name).isEmpty
                        : projectProcesses.contains { projectApp.matcher.matchesProjectApp($0) }
                }
                .map(\.appId),
        )
    }
}

extension ProjectFilter {
    @MainActor func matches(_ app: any AbstractApp) -> Bool { matches(project: getProjectName(of: app)) }

    @MainActor func matches(window: Window) -> Bool { matches(project: getWindowProjectName(window)) }

    @MainActor private func matches(project: String?) -> Bool {
        switch self {
            case .name(let name): project == name
            case .global: project == nil
            case .active: activeProjectName != nil && project == activeProjectName
        }
    }
}
