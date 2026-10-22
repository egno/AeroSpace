import AppKit
import Common

/// Per-window ownership. One process (e.g. the personal Chrome) is shared by all projects, and each of its windows
/// belongs to a project. Such processes are matched by app definitions with `window-if` ("per-window" apps).
/// They are never hidden as a whole. Instead, windows of inactive projects leave the layout the same way windows of
/// macOS hidden apps do (MacosHiddenAppsWindowsContainer, see normalizeLayoutReason), and layoutWorkspaces parks them in
/// the corner of the monitor.

struct WindowOwnershipOverride: Equatable {
    let pid: pid_t
    /// nil means global
    let project: String?
}

struct PendingProjectWindowAssignment: Equatable {
    let project: String
    let appId: String
    let deadline: Date
}

/// window id -> ownership. Set by move-window-to-project and by `new-windows`. Beats `window-if`. Lives while the process lives
@MainActor var windowOwnershipOverrides: [UInt32: WindowOwnershipOverride] = [:]
/// window id -> ownership decided by `window-if` matchers. Only windows of per-window processes.
/// Window titles change, that's why it's recomputed on every normalizeLayoutReason
@MainActor private var windowIfOwnershipCache: [UInt32: ProjectOwnership] = [:]
/// pid -> whether the process is matched by a per-window app definition
@MainActor private var perWindowProcessCache: [pid_t: Bool] = [:]
/// Windows that left the layout because they belong to an inactive project -> when it happened
@MainActor var projectHiddenWindows: [UInt32: Date] = [:]
/// project-launch of a per-window app. The next new window of the app goes to the project
@MainActor var pendingProjectWindowAssignments: [PendingProjectWindowAssignment] = []
private let pendingProjectWindowAssignmentTimeout: TimeInterval = 10
/// Our own focus changes (on-window-assigned focuses the window before it gets hidden) must not look like R4 activation
private let projectWindowActivationGracePeriod: TimeInterval = 1
/// AppleScript in on-window-assigned must see the assigned window as the frontmost one
private let onWindowAssignedTimeout: TimeInterval = 3

@MainActor func resetWindowOwnershipCaches() {
    windowIfOwnershipCache = [:]
    perWindowProcessCache = [:]
}

/// Window ids and pids are valid only while the process lives
@MainActor func gcWindowOwnershipState(alivePids: Set<pid_t>) {
    perWindowProcessCache = perWindowProcessCache.filter { alivePids.contains($0.key) }
    let aliveWindowIds = getAllProjectWindows().map(\.windowId).toSet()
    windowOwnershipOverrides = windowOwnershipOverrides.filter { alivePids.contains($0.value.pid) && aliveWindowIds.contains($0.key) }
    projectHiddenWindows = projectHiddenWindows.filter { aliveWindowIds.contains($0.key) }
}

@MainActor var hasPerWindowProjectApps: Bool { config.projects.contains { $0.apps.contains(where: \.isPerWindow) } }

@MainActor func isPerWindowProcess(_ app: any AbstractApp) -> Bool {
    if config.projects.isEmpty { return false }
    if let cached = perWindowProcessCache[app.pid] { return cached }
    let result = config.projects.contains { $0.apps.contains { $0.isPerWindow && $0.matcher.matchesProjectApp(app) } }
    perWindowProcessCache[app.pid] = result
    return result
}

/// Manual override > `window-if` match > ownership of the process
@MainActor func getWindowProjectOwnership(_ window: Window) -> ProjectOwnership {
    if config.projects.isEmpty { return .global }
    if let override = windowOwnershipOverrides[window.windowId], override.pid == window.app.pid {
        return override.project.map(ProjectOwnership.project) ?? .global
    }
    if let ownership = windowIfOwnershipCache[window.windowId], ownership != .global { return ownership }
    return getProjectOwnership(window.app)
}

@MainActor func getWindowProjectName(_ window: Window) -> String? { getWindowProjectOwnership(window).projectName }

/// `project == nil` makes the window global
@MainActor func setWindowOwnershipOverride(_ window: Window, project: String?) {
    windowOwnershipOverrides[window.windowId] = WindowOwnershipOverride(pid: window.app.pid, project: project)
}

/// A window matches a project if its process matches the project's per-window app (`if`) and the window matches `window-if`
@MainActor func resolveWindowIfOwnership(_ window: WindowWithPrefetchedTitle, _ projects: [Project]) -> ProjectOwnership {
    let candidates = projects.filter { project in
        project.apps.contains { projectApp in
            projectApp.windowMatcher?.matchesProjectWindow(window) == true && projectApp.matcher.matchesProjectApp(window.window.app)
        }
    }.map(\.name)
    return switch candidates.count {
        case 0: .global
        case 1: .project(candidates.first.orDie())
        default: .conflict(candidates)
    }
}

@MainActor private func getWindowIfOwnership(_ window: Window, _ cm: CancellationMode) async throws -> ProjectOwnership {
    let window = try await WindowWithPrefetchedTitle.resolveWindow(window, for: .window(.windowTitle), cm)
    return resolveWindowIfOwnership(window, config.projects)
}

/// Window titles change (e.g. Chrome's "Name window..."). Recompute `window-if` ownership of every window of per-window processes
@MainActor func refreshWindowIfOwnership(_ cm: CancellationMode) async throws {
    if !hasPerWindowProjectApps {
        windowIfOwnershipCache = [:]
        return
    }
    var result: [UInt32: ProjectOwnership] = [:]
    for window in getAllProjectWindows() where isPerWindowProcess(window.app) {
        result[window.windowId] = try await getWindowIfOwnership(window, cm)
    }
    windowIfOwnershipCache = result
}

/// Windows of all workspaces, hidden and minimized ones included. Popups are excluded
@MainActor func getAllProjectWindows() -> [Window] {
    let windows: [Window] = isUnitTest
        ? Workspace.all.flatMap(\.allLeafWindowsRecursive) + macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self)
        : MacWindow.allWindows
    return windows.filter { window in
        switch window.windowParentCases {
            case .macosPopupWindowsContainer, .unbound: false
            case .tilingContainer, .floatingWindowsContainer, .macosHiddenAppsWindowsContainer,
                 .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer: true
        }
    }
}

/// The window of a per-window process belongs to an inactive project. Such windows leave the layout and get parked in
/// the corner (see normalizeLayoutReason and layoutWorkspaces)
@MainActor func isWindowHiddenByProject(_ window: Window) -> Bool {
    guard TrayMenuModel.shared.isEnabled, isPerWindowProcess(window.app), let project = getWindowProjectName(window) else { return false }
    return project != activeProjectName
}

/// Called by normalizeLayoutReason for every window
@MainActor func rememberWindowHiddenByProject(_ window: Window, _ isHidden: Bool) {
    if !isHidden {
        projectHiddenWindows.removeValue(forKey: window.windowId)
    } else if projectHiddenWindows[window.windowId] == nil {
        projectHiddenWindows[window.windowId] = .now
    }
}

extension Window {
    /// The window belongs to an inactive project. It's not part of the layout and it's parked in the corner
    @MainActor var isParkedByProject: Bool { projectHiddenWindows[windowId] != nil && parent is MacosHiddenAppsWindowsContainer }
}

/// The per-window app definition that handles the window's process. Prefers the definition referenced by the project
@MainActor private func getPerWindowProjectApp(_ app: any AbstractApp, project: String?) -> ProjectApp? {
    let projects = config.projects.filter { $0.name == project } + config.projects
    return projects.lazy.flatMap(\.apps).first { $0.isPerWindow && $0.matcher.matchesProjectApp(app) }
}

/// on-window-assigned waits for the processes spawned by exec-and-forget. nil when nobody collects them
@MainActor var execAndForgetSpawnedProcesses: [Process]? = nil

/// Sets the override and runs `on-window-assigned`. The window is focused (frontmost in its app) while the callback runs,
/// since AppleScript's `window 1` of Chrome is its most recently active window
@MainActor func assignWindowToProject(_ window: Window, project: String?) async {
    setWindowOwnershipOverride(window, project: project)
    guard let callback = getPerWindowProjectApp(window.app, project: project)?.onWindowAssigned else { return }
    if case .empty = callback { return }
    window.nativeFocus()
    let env = CmdEnv.defaultEnv.withWindowId(window.windowId).withEnvVars([AEROSPACE_PROJECT: project ?? ""])
    if isUnitTest {
        projectSideEffectsForTests.append(.windowAssigned(windowId: window.windowId, env: env.asMap))
        return
    }
    execAndForgetSpawnedProcesses = []
    _ = await callback.run(env, CmdIoImpl.emptyStdinIgnoringOut)
    let processes = execAndForgetSpawnedProcesses ?? []
    execAndForgetSpawnedProcesses = nil
    let deadline = Date.now.addingTimeInterval(onWindowAssignedTimeout)
    while Date.now < deadline && processes.contains(where: \.isRunning) {
        if (try? await Task.sleep(for: .milliseconds(10))) == nil { break } // Cancelled
    }
}

/// move-window-to-project
@MainActor func moveWindowToProject(_ window: Window, project: String?) async {
    projectSwitchesInProgress += 1
    defer { projectSwitchesInProgress -= 1 }
    await assignWindowToProject(window, project: project)
    await reapplyProjectVisibility()
    refocusIfFocusedWindowIsHidden()
    // on-window-assigned focused the window. Give the focus back
    focus.windowOrNil?.nativeFocus()
    saveProjectState()
}

/// The focused window got hidden by project ownership change
@MainActor func refocusIfFocusedWindowIsHidden() {
    guard let window = focus.windowOrNil, window.isParkedByProject || projectHiddenPids.contains(window.app.pid) else { return }
    if let newFocus = getFocusAfterProjectSwitch(activeProjectName, preferredPid: nil) {
        _ = newFocus.focusWindow()
    } else {
        _ = setFocus(to: LiveFocus(windowOrNil: nil, workspace: focus.workspace))
    }
}

/// `new-windows = 'active-project'` and project-launch of per-window apps. Called once for every newly detected window
@MainActor func assignNewProjectWindowIfNeeded(_ window: Window) async {
    if isStartup || !isPerWindowProcess(window.app) || windowOwnershipOverrides[window.windowId] != nil { return }
    switch window.windowParentCases {
        case .macosPopupWindowsContainer, .unbound: return
        case .tilingContainer, .floatingWindowsContainer, .macosHiddenAppsWindowsContainer,
             .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer: break
    }
    guard let ownership = try? await getWindowIfOwnership(window, .nonCancellable) else { return }
    windowIfOwnershipCache[window.windowId] = ownership
    if ownership != .global { return } // `window-if` decides
    guard let project = takePendingProjectWindowAssignment(window.app) ?? getActiveProjectForNewWindow(window.app) else { return }
    projectSwitchesInProgress += 1
    defer { projectSwitchesInProgress -= 1 }
    await assignWindowToProject(window, project: project)
    if project != activeProjectName {
        await reapplyProjectVisibility()
        refocusIfFocusedWindowIsHidden()
        focus.windowOrNil?.nativeFocus()
    }
    saveProjectState()
}

@MainActor private func getActiveProjectForNewWindow(_ app: any AbstractApp) -> String? {
    guard let project = config.projects.first(where: { $0.name == activeProjectName }) else { return nil }
    let isAssigned = project.apps.contains { $0.isPerWindow && $0.newWindows == .activeProject && $0.matcher.matchesProjectApp(app) }
    return isAssigned ? project.name : nil
}

@MainActor func addPendingProjectWindowAssignment(project: String, appId: String) {
    pendingProjectWindowAssignments.append(PendingProjectWindowAssignment(
        project: project,
        appId: appId,
        deadline: .now.addingTimeInterval(pendingProjectWindowAssignmentTimeout),
    ))
}

@MainActor private func takePendingProjectWindowAssignment(_ app: any AbstractApp) -> String? {
    pendingProjectWindowAssignments.removeAll { $0.deadline < .now }
    let index = pendingProjectWindowAssignments.firstIndex { pending in
        config.projects.first(where: { $0.name == pending.project })?.apps
            .first(where: { $0.appId == pending.appId })?.matcher.matchesProjectApp(app) == true
    }
    return index.map { pendingProjectWindowAssignments.remove(at: $0).project }
}

/// R4 for per-window apps. The native focus landed on a window of an inactive project (cmd-tab brings the most recently
/// active window of the app, Dock click, notification click). Returns true if the native focus must be ignored
@MainActor func handleInactiveProjectWindowActivation(_ nativeFocused: Window?) async -> Bool {
    guard let window = nativeFocused, isNativeFocusChanged(window), isWindowHiddenByProject(window),
          let project = getWindowProjectName(window) else { return false }
    let isHiddenRecently = projectHiddenWindows[window.windowId].map { Date.now.timeIntervalSince($0) < projectWindowActivationGracePeriod } == true
    if isProjectSwitchInProgress || isHiddenRecently {
        // AeroSpace itself focused the window right before hiding it (e.g. for on-window-assigned)
        markNativeFocusAsSeen(window)
        return true
    }
    switch await getInactiveProjectActivationPolicy() {
        case ._switch:
            await switchProject(to: project, preferredPid: nil, preferredWindowId: window.windowId)
            return false
        case .rehide:
            markNativeFocusAsSeen(window)
            focus.windowOrNil?.nativeFocus()
            return true
    }
}

extension Shell where T == any Command {
    @MainActor func matchesProjectWindow(_ window: WindowWithPrefetchedTitle) -> Bool { matchesProjectObj(.window(window)) }
}
