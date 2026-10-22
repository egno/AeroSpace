import AppKit
import Common

enum ProjectLaunchStep: Equatable {
    /// The app instance is running. Focus its most recently used window
    case focus(windowId: UInt32)
    /// The app instance of an inactive project is running. Switch to the project and focus the app's window
    case switchProject(String, preferredPid: pid_t)
    /// Run the launch command. `project == nil` for global-launch
    case launch(script: String, project: String?)
}

enum ProjectSideEffect: Equatable {
    case launch(script: String, env: [String: String])
    case terminate(pid: pid_t)
}

/// Unit tests must not spawn processes and must not quit apps. The side effects are recorded instead
@MainActor var projectSideEffectsForTests: [ProjectSideEffect] = []

/// The processes of the project's instance of the app
@MainActor func getProjectAppInstancePids(_ projectApp: ProjectApp, project: String, _ apps: [any AbstractApp]) -> [pid_t] {
    apps.filter { getProjectName(of: $0) == project && projectApp.matcher.matchesProjectApp($0) }.map(\.pid).sorted()
}

/// R5.1b. The global instance of the app: processes with the app's bundle ID that match no project
@MainActor func getGlobalAppInstancePids(bundleId: String, _ apps: [any AbstractApp]) -> [pid_t] {
    apps.filter { $0.rawAppBundleId == bundleId && getProjectName(of: $0) == nil }.map(\.pid).sorted()
}

/// The most recently used focusable window of the processes
@MainActor func getMruWindow(ofPids pids: [pid_t]) -> Window? {
    let pids = pids.toSet()
    let candidates: [Window?] = mruWindowIds.map { Window.get(byId: $0) } + Workspace.all.flatMap(\.allLeafWindowsRecursive)
    return candidates.lazy.compactMap { $0 }.first(where: { pids.contains($0.app.pid) && $0.isFocusableAfterProjectSwitch })
}

/// The process of the most recently used window (hidden windows count). Falls back to the first process
@MainActor private func getMruPid(_ pids: [pid_t]) -> pid_t? {
    mruWindowIds.lazy.compactMap { Window.get(byId: $0)?.app.pid }.first(where: pids.contains) ?? pids.first
}

/// Substitutes `{open}` with shell-quoted, space-separated items. A leading `~` is expanded to `home`,
/// since quoting prevents the shell from expanding it
func substituteOpenPlaceholder(_ template: String, _ items: [String], home: String) -> Result<String, String> {
    if !template.contains(openPlaceholder) {
        return items.isEmpty
            ? .success(template)
            : .failure("The launch command doesn't contain \(openPlaceholder) placeholder. Items to open can't be passed: \(template)")
    }
    let quoted = items.map { expandTilde($0, home: home).shellQuoted }.joined(separator: " ")
    return .success(template.replacingOccurrences(of: openPlaceholder, with: quoted))
}

private func expandTilde(_ item: String, home: String) -> String {
    if item == "~" { return home }
    if item.starts(with: "~/") { return home + item.dropFirst() }
    return item
}

extension String {
    /// POSIX shell single quoting
    var shellQuoted: String { "'" + replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// R5.1, R5.1a, R5.2
/// - No `appIds`: launch every `autostart` app whose instance isn't running. Apps without `launch` command are skipped
/// - `appIds`, the instance is running: focus its MRU window (switch to the project if it's inactive).
///   If the instance has no windows to focus, run the launch command
/// - `appIds` and `open`: run the launch command with `open` items even if the instance is running
@MainActor func getProjectLaunchPlan(
    _ project: Project,
    appIds: [String],
    open: [String],
    _ apps: [any AbstractApp],
    home: String,
) -> Result<[ProjectLaunchStep], String> {
    if appIds.isEmpty {
        return project.apps
            .filter { $0.autostart && $0.launch != nil && getProjectAppInstancePids($0, project: project.name, apps).isEmpty }
            .mapAllOrFailure { projectApp in
                getLaunchStep(projectApp.launch.orDie(), projectApp.open, project: project.name, appId: projectApp.appId, home: home)
            }
    }
    let projectApps = appIds.map { appId in project.apps.first(where: { $0.appId == appId }) }
    if let index = projectApps.firstIndex(where: { $0 == nil }) {
        return .failure("Project '\(project.name)' doesn't reference app '\(appIds[index])'")
    }
    return projectApps.map { $0.orDie() }.mapAllOrFailure { projectApp in
        let pids = getProjectAppInstancePids(projectApp, project: project.name, apps)
        if !pids.isEmpty && open.isEmpty {
            if project.name != activeProjectName {
                return .success(.switchProject(project.name, preferredPid: getMruPid(pids).orDie()))
            }
            if let window = getMruWindow(ofPids: pids) {
                return .success(.focus(windowId: window.windowId))
            }
        }
        guard let launch = projectApp.launch else {
            return .failure("App '\(projectApp.appId)' of project '\(project.name)' has no 'launch' command")
        }
        return getLaunchStep(launch, open.isEmpty ? projectApp.open : open, project: project.name, appId: projectApp.appId, home: home)
    }
}

/// R5.1b. No active project: target the global instances of the apps
@MainActor func getGlobalAppLaunchPlan(
    appIds: [String],
    open: [String],
    _ apps: [any AbstractApp],
    home: String,
) -> Result<[ProjectLaunchStep], String> {
    appIds.mapAllOrFailure { appId in
        guard let def = config.projectApps[appId] else {
            return .failure("Unknown project app '\(appId)'. It must be declared in [project-apps.\(appId)]")
        }
        guard let bundleId = def.bundleId else {
            return .failure("App '\(appId)' has no 'bundle-id'. It's required to find the global instance")
        }
        let pids = getGlobalAppInstancePids(bundleId: bundleId, apps)
        if !pids.isEmpty && open.isEmpty, let window = getMruWindow(ofPids: pids) {
            return .success(.focus(windowId: window.windowId))
        }
        guard let globalLaunch = def.globalLaunch else {
            return .failure("App '\(appId)' has no 'global-launch' command")
        }
        return getLaunchStep(globalLaunch, open, project: nil, appId: appId, home: home)
    }
}

private func getLaunchStep(_ template: String, _ open: [String], project: String?, appId: String, home: String) -> Result<ProjectLaunchStep, String> {
    substituteOpenPlaceholder(template, open, home: home)
        .map { ProjectLaunchStep.launch(script: $0, project: project) }
        .mapError { "App '\(appId)': \($0)" }
}

@MainActor func executeProjectLaunchPlan(_ steps: [ProjectLaunchStep], _ io: CmdIo) async -> BinaryExitCode {
    var result: BinaryExitCode = .succ
    for step in steps {
        switch step {
            case .focus(let windowId):
                if Window.get(byId: windowId)?.focusWindow() != true {
                    result = .fail(io.err("Failed to focus window \(windowId)"))
                }
            case .switchProject(let project, let pid):
                await switchProject(to: project, preferredPid: pid)
            case .launch(let script, let project):
                if !runProjectLaunchCommand(script, project: project) {
                    result = .fail(io.err("Failed to run: \(script)"))
                }
        }
    }
    return result
}

/// R5.4: launch commands get AEROSPACE_PROJECT env variable (empty for global-launch)
@MainActor private func runProjectLaunchCommand(_ script: String, project: String?) -> Bool {
    let env = [AEROSPACE_PROJECT: project ?? ""]
    if isUnitTest {
        projectSideEffectsForTests.append(.launch(script: script, env: env))
        return true
    }
    // Don't forward AEROSPACE_WINDOW_ID/AEROSPACE_WORKSPACE. The launched app would inherit them
    return execAndForget(script, env: env)
}

@MainActor func launchMissingProjectApps(_ project: Project, _ io: CmdIo) async -> BinaryExitCode {
    switch getProjectLaunchPlan(project, appIds: [], open: [], getRunningApps(), home: homeDirPath) {
        case .success(let steps): await executeProjectLaunchPlan(steps, io)
        case .failure(let msg): .fail(io.err(msg))
    }
}

var homeDirPath: String { FileManager.default.homeDirectoryForCurrentUser.path }

/// R5.3: all processes owned by the project
@MainActor func getProjectQuitTargets(_ project: String, _ apps: [any AbstractApp]) -> [pid_t] {
    apps.filter { getProjectName(of: $0) == project }.map(\.pid).sorted()
}

/// Graceful quit, the same as cmd-q. Apps may ask for confirmation
@MainActor func terminateProcess(_ pid: pid_t) -> Bool {
    if isUnitTest {
        projectSideEffectsForTests.append(.terminate(pid: pid))
        return true
    }
    return NSRunningApplication(processIdentifier: pid)?.terminate() == true
}
