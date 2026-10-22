import AppKit
import Common

struct ProjectCommand: Command {
    let args: ProjectCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let projectNames = config.projects.map(\.name)
        if projectNames.isEmpty { return .fail(io.err("No projects are configured. Please declare [[projects]] in the config")) }
        let target: String?
        switch args.target {
            case .noProject:
                target = nil
            case .direct(let name):
                guard projectNames.contains(name) else {
                    return .fail(io.err("Unknown project '\(name)'. Configured projects: \(projectNames.joined(separator: ", "))"))
                }
                target = name
            case .relative(let nextPrev):
                switch getNextPrevProject(projectNames, current: activeProjectName, nextPrev, wrapAround: args.wrapAround) {
                    case .success(let name): target = name
                    case .failure(let msg): return .fail(io.err(msg))
                }
        }
        await switchProject(to: target)
        return .succ
    }
}

/// With no active project, 'next' picks the first project and 'prev' picks the last one
func getNextPrevProject(_ projectNames: [String], current: String?, _ nextPrev: NextPrev, wrapAround: Bool) -> Result<String, String> {
    if projectNames.isEmpty { return .failure("The list of projects is empty") }
    let index: Int = switch (current.flatMap { projectNames.firstIndex(of: $0) }, nextPrev) {
        case (nil, .next): 0
        case (nil, .prev): projectNames.count - 1
        case (let index?, .next): index + 1
        case (let index?, .prev): index - 1
    }
    return wrapAround
        ? projectNames.get(wrappingIndex: index).toResult("The list of projects is empty")
        : projectNames.getOrNil(atIndex: index).toResult(
            index >= projectNames.count ? "Reached the end of the projects list" : "Reached the beginning of the projects list",
        )
}
