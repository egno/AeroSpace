import AppKit
import Common

/// Small JSON file that survives AeroSpace restarts. It's state, not config, hence XDG_STATE_HOME
/// https://specifications.freedesktop.org/basedir-spec/latest/
private struct ProjectStateFile: Codable, Equatable {
    var activeProject: String? = nil
    var prevActiveProject: String? = nil
    var hasPrevActiveProject: Bool = false
    /// Allows to recover apps hidden by AeroSpace if AeroSpace crashed
    var hiddenPids: [Int32] = []
    /// move-app-to-project overrides. Optional for compatibility with older state files
    var ownershipOverrides: [OwnershipOverride]? = nil

    struct OwnershipOverride: Codable, Equatable {
        let pid: Int32
        /// nil means global
        let project: String?
        /// pid + argv identify the process. Pids are reused after reboot
        let args: String?
    }
}

private var projectStateFileUrl: URL {
    let stateHome = ProcessInfo.processInfo.environment["XDG_STATE_HOME"].map { URL(filePath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/state")
    return stateHome.appending(path: "aerospace/projects.json")
}

/// State must not be saved before it's restored. Otherwise, the startup would overwrite the persisted active project
@MainActor private var isProjectStateRestored = false

@MainActor func saveProjectState() {
    if isUnitTest || !isProjectStateRestored { return }
    let state = ProjectStateFile(
        activeProject: activeProjectName,
        prevActiveProject: prevActiveProjectName.flatMap { $0 },
        hasPrevActiveProject: prevActiveProjectName != nil,
        hiddenPids: projectHiddenPids.sorted(),
        ownershipOverrides: projectOwnershipOverrides.sorted(by: { $0.key < $1.key }).map { pid, ownership in
            .init(pid: pid, project: ownership.projectName, args: getRunningApps().first(where: { $0.pid == pid })?.args)
        },
    )
    guard let data = try? JSONEncoder.aeroSpaceDefault.encode(state) else { return }
    let url = projectStateFileUrl
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url, options: .atomic)
}

/// R3.7: restore the active project and hide processes of inactive projects
@MainActor func restoreProjectStateOnStartup() async {
    if isUnitTest || config.projects.isEmpty { return }
    let state = (try? Data(contentsOf: projectStateFileUrl)).flatMap { try? JSONDecoder().decode(ProjectStateFile.self, from: $0) }
        ?? ProjectStateFile()
    let names = config.projects.map(\.name).toSet()
    activeProjectName = state.activeProject.flatMap { names.contains($0) ? $0 : nil }
    if state.hasPrevActiveProject {
        prevActiveProjectName = .some(state.prevActiveProject.flatMap { names.contains($0) ? $0 : nil })
    }
    let runningApps = getRunningApps()
    for o in state.ownershipOverrides ?? [] where o.project.map(names.contains) != false {
        if let app = runningApps.first(where: { $0.pid == o.pid }), app.args == o.args {
            setProjectOwnershipOverride(pid: o.pid, project: o.project)
        }
    }
    let projectPids = MacApp.allAppsMap.values.filter { getProjectName(of: $0) != nil }.map(\.pid).toSet()
    projectHiddenPids = Set(state.hiddenPids).intersection(projectPids)
    isProjectStateRestored = true
    await reapplyProjectVisibility()
    saveProjectState()
}

@MainActor func onProjectsConfigReloaded() async {
    resetProjectOwnershipCache()
    if !isProjectStateRestored { return }
    if case let prev?? = prevActiveProjectName, !config.projects.contains(where: { $0.name == prev }) {
        prevActiveProjectName = nil
    }
    projectOwnershipOverrides = projectOwnershipOverrides.filter { _, ownership in
        ownership.projectName.map { name in config.projects.contains(where: { $0.name == name }) } != false
    }
    if let active = activeProjectName, !config.projects.contains(where: { $0.name == active }) {
        activeProjectName = nil
        await onProjectChanged(prev: active, new: nil)
    }
    await reapplyProjectVisibility()
    saveProjectState()
}
