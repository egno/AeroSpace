import AppKit
import Common

enum ProjectOwnership: Equatable {
    case global
    case project(String)
    /// Several projects claim the process with the same priority. It's a config error. The process is treated as global
    case conflict([String])

    var projectName: String? {
        switch self {
            case .project(let name): name
            case .global, .conflict: nil
        }
    }
}

/// pid -> ownership. Ownership is decided once per process and recomputed on reload-config
@MainActor private var projectOwnershipCache: [pid_t: ProjectOwnership] = [:]
@MainActor var activeProjectName: String? = nil
/// Used by project-back-and-forth. `.some(nil)` means that "no project" was active previously
@MainActor var prevActiveProjectName: String?? = nil
/// Pids that AeroSpace hid because of project switching. User's cmd-h hidden apps are never in the set
@MainActor var projectHiddenPids: Set<pid_t> = []
/// project name -> window id
@MainActor var projectMruWindowIds: [String: UInt32] = [:]
/// Most recently focused windows of all apps, the most recent first. Used to focus the MRU window of an app instance
@MainActor var mruWindowIds: [UInt32] = []
private let mruWindowIdsLimit = 100
/// pid -> ownership. Set by move-app-to-project. Beats the config rules. Lives until the process exits
@MainActor var projectOwnershipOverrides: [pid_t: ProjectOwnership] = [:]
/// Unit tests don't have real running apps
@MainActor var runningAppsForTests: [any AbstractApp] = []
/// A counter, since window assignments (see projectWindows.swift) may interleave with switching
@MainActor var projectSwitchesInProgress = 0
@MainActor var isProjectSwitchInProgress: Bool { projectSwitchesInProgress > 0 }

@MainActor func getProjectOwnership(_ app: any AbstractApp) -> ProjectOwnership {
    if config.projects.isEmpty { return .global }
    if let override = projectOwnershipOverrides[app.pid] { return override }
    if let cached = projectOwnershipCache[app.pid] { return cached }
    let result = resolveProjectOwnership(app, config.projects)
    projectOwnershipCache[app.pid] = result
    return result
}

@MainActor func getProjectName(of app: any AbstractApp) -> String? { getProjectOwnership(app).projectName }

@MainActor func resetProjectOwnershipCache() {
    projectOwnershipCache = [:]
    resetWindowOwnershipCaches()
}

/// `project == nil` makes the process global
@MainActor func setProjectOwnershipOverride(pid: pid_t, project: String?) {
    projectOwnershipOverrides[pid] = project.map(ProjectOwnership.project) ?? .global
}

@MainActor func getRunningApps() -> [any AbstractApp] {
    isUnitTest ? runningAppsForTests : MacApp.allAppsMap.values.filter { !$0.nsApp.isTerminated }
}

/// Shared (`{project}`-specific) match beats whole-app match. The remaining tie is a conflict.
/// Per-window app definitions don't own processes, they own windows (see getWindowProjectOwnership)
@MainActor func resolveProjectOwnership(_ app: any AbstractApp, _ projects: [Project]) -> ProjectOwnership {
    var shared: [String] = []
    var whole: [String] = []
    for project in projects {
        for projectApp in project.apps where !projectApp.isPerWindow && projectApp.matcher.matchesProjectApp(app) {
            switch projectApp.isShared {
                case true: if !shared.contains(project.name) { shared.append(project.name) }
                case false: if !whole.contains(project.name) { whole.append(project.name) }
            }
        }
    }
    let candidates = shared.isEmpty ? whole : shared
    return switch candidates.count {
        case 0: .global
        case 1: .project(candidates.first.orDie())
        default: .conflict(candidates)
    }
}

@MainActor func getProjectOwnershipConflictErrors(_ projects: [Project], _ apps: [any AbstractApp]) -> [String] {
    apps.sortedBy { $0.pid }.compactMap { app in
        switch resolveProjectOwnership(app, projects) {
            case .conflict(let candidates):
                "[ERROR] projects: Process \(app.pid) (\(app.rawAppBundleId ?? app.name ?? "")) matches several projects " +
                    "with the same priority: \(candidates.joined(separator: ", ")). The process is treated as global"
            case .global, .project: nil
        }
    }
}

extension Shell where T == any Command {
    /// Evaluates project-apps matcher against the app (process). See parseProjectAppMatcher
    @MainActor func matchesProjectApp(_ app: any AbstractApp) -> Bool { matchesProjectObj(.app(app)) }

    /// `obj` is an app (`if`) or a window (`window-if`)
    @MainActor func matchesProjectObj(_ obj: AeroObj) -> Bool {
        switch self {
            case .empty: return true
            case .and(let it): return it.allSatisfy { $0.matchesProjectObj(obj) }
            case .or(let it): return it.contains { $0.matchesProjectObj(obj) }
            case .seq(let it): return it.last?.matchesProjectObj(obj) ?? true
            case .pipe: return false
            case .cmd(let cmd):
                switch cmd {
                    case is TrueCommand: return true
                    case is FalseCommand: return false
                    case let cmd as TestCommand: return evalProjectMatcherTest(cmd.args, obj) == true
                    case let cmd as TestNotCommand: return evalProjectMatcherTest(cmd.args.testArgs, obj) == false
                    default: return false
                }
        }
    }
}

@MainActor private func evalProjectMatcherTest(_ args: TestCmdArgs, _ obj: AeroObj) -> Bool? {
    guard case .success(let lhs) = args.lhs.val.expandFormatVar(obj: obj) else { return nil }
    return try? evalTestCondition(lhs, lhsVar: args.lhs.val, args.infixOperator.val, args.rhs.val).get()
}

struct ProjectAppState: Equatable {
    let pid: pid_t
    let project: String?
    let isHidden: Bool
}

struct ProjectVisibilityPlan: Equatable {
    var toUnhide: [pid_t] = []
    var toHide: [pid_t] = []
}

/// - Active project processes hidden by AeroSpace are unhidden
/// - Visible processes of inactive projects are hidden
/// - Processes hidden by the user (not in projectHiddenPids) stay user-owned and aren't touched
/// - Global processes are never touched, unless AeroSpace hid them earlier (e.g. the project was removed from the config)
func getProjectVisibilityPlan(activeProject: String?, apps: [ProjectAppState], projectHiddenPids: Set<pid_t>) -> ProjectVisibilityPlan {
    var result = ProjectVisibilityPlan()
    for app in apps.sortedBy({ $0.pid }) {
        let isHiddenByUs = projectHiddenPids.contains(app.pid)
        switch app.project {
            case nil, activeProject:
                if isHiddenByUs { result.toUnhide.append(app.pid) }
            case _?:
                if !app.isHidden { result.toHide.append(app.pid) }
        }
    }
    return result
}

/// With `automatically-unhide-macos-hidden-apps = true`, AeroSpace unhides apps on every hide event.
/// Apps hidden by project switching must stay hidden
@MainActor func getPidsToAutoUnhide(_ pids: [pid_t]) -> [pid_t] {
    pids.filter { !projectHiddenPids.contains($0) }
}

/// Per-window processes are never hidden as a whole (their windows are hidden one by one), so they look global here
@MainActor func getProjectAppStates() -> [ProjectAppState] {
    MacApp.allAppsMap.values.map { getProjectAppState($0, isHidden: $0.nsApp.isHidden) }
}

@MainActor func getProjectAppState(_ app: any AbstractApp, isHidden: Bool) -> ProjectAppState {
    ProjectAppState(pid: app.pid, project: isPerWindowProcess(app) ? nil : getProjectName(of: app), isHidden: isHidden)
}

@MainActor private func gcProjectState() {
    let alivePids = getRunningApps().map(\.pid).toSet()
    projectOwnershipCache = projectOwnershipCache.filter { alivePids.contains($0.key) }
    projectOwnershipOverrides = projectOwnershipOverrides.filter { alivePids.contains($0.key) }
    projectHiddenPids = projectHiddenPids.intersection(alivePids)
    gcWindowOwnershipState(alivePids: alivePids)
}

@MainActor func switchProject(to target: String?, preferredPid: pid_t? = nil, preferredWindowId: UInt32? = nil) async {
    projectSwitchesInProgress += 1
    defer { projectSwitchesInProgress -= 1 }
    let prev = activeProjectName
    if prev != target {
        prevActiveProjectName = .some(prev)
    }
    activeProjectName = target
    await reapplyProjectVisibility()
    if let window = getFocusAfterProjectSwitch(target, preferredPid: preferredPid, preferredWindowId: preferredWindowId) {
        _ = window.focusWindow()
    } else {
        _ = setFocus(to: LiveFocus(windowOrNil: nil, workspace: focus.workspace))
    }
    // Hiding apps makes macOS activate some other app. Make sure that macOS focus is in sync
    focus.windowOrNil?.nativeFocus()
    saveProjectState()
    if prev != target {
        await onProjectChanged(prev: prev, new: target)
    }
}

@MainActor func reapplyProjectVisibility() async {
    if config.projects.isEmpty && projectHiddenPids.isEmpty && projectHiddenWindows.isEmpty { return }
    gcProjectState()
    let plan = getProjectVisibilityPlan(activeProject: activeProjectName, apps: getProjectAppStates(), projectHiddenPids: projectHiddenPids)
    await applyProjectVisibility(plan)
}

/// `enable off`. Windows of per-window processes come back, since isWindowHiddenByProject is false for disabled AeroSpace
@MainActor func unhideAllProjectHiddenApps() async {
    if projectHiddenPids.isEmpty && projectHiddenWindows.isEmpty { return }
    await applyProjectVisibility(ProjectVisibilityPlan(toUnhide: projectHiddenPids.sorted(), toHide: []))
}

@MainActor func unhideAllProjectHiddenAppsForTermination() {
    for pid in projectHiddenPids {
        NSRunningApplication(processIdentifier: pid)?.unhide()
    }
    projectHiddenPids = []
    saveProjectState()
}

@MainActor private func applyProjectVisibility(_ plan: ProjectVisibilityPlan) async {
    projectHiddenPids.subtract(plan.toUnhide)
    projectHiddenPids.formUnion(plan.toHide)
    let hasAppChanges = !plan.toUnhide.isEmpty || !plan.toHide.isEmpty
    if hasAppChanges {
        // Unhide first, then hide. It minimizes flickering
        await setAppsHidden(plan.toUnhide, false)
        await setAppsHidden(plan.toHide, true)
        await waitUntilAppsHiddenStateSettles(plan)
    }
    // Windows of per-window processes are hidden only by the layout
    let hasWindowChanges = hasPerWindowProjectApps || !projectHiddenWindows.isEmpty
    if hasAppChanges && !isUnitTest || hasWindowChanges {
        try? await normalizeLayoutReason() // Move windows to/from MacosHiddenAppsWindowsContainer
    }
}

/// AX calls take ~35-55ms per app. Issue them concurrently on the per-app AX threads
@MainActor private func setAppsHidden(_ pids: [pid_t], _ value: Bool) async {
    if serverArgs.isReadOnly { return }
    await withTaskGroup(of: Void.self) { group in
        for pid in pids {
            group.addTask { @Sendable @MainActor in
                guard let app = MacApp.allAppsMap[pid] else { return }
                if await !app.setAxHidden(value) {
                    // NSRunningApplication.hide() is known to return false even if it takes the effect. Don't trust the result
                    _ = value ? app.nsApp.hide() : app.nsApp.unhide()
                }
            }
        }
    }
}

/// Don't trust return values of hide/unhide APIs. Observe isHidden instead
@MainActor private func waitUntilAppsHiddenStateSettles(_ plan: ProjectVisibilityPlan) async {
    let deadline = Date.now.addingTimeInterval(0.5)
    while Date.now < deadline {
        let isSettled = plan.toUnhide.allSatisfy { MacApp.allAppsMap[$0]?.nsApp.isHidden != true } &&
            plan.toHide.allSatisfy { MacApp.allAppsMap[$0]?.nsApp.isHidden != false }
        if isSettled { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// R3.2: target project's MRU window -> top window of the focused workspace -> empty focused workspace
/// `preferredWindowId` (R4 for per-window apps) beats `preferredPid`
@MainActor func getFocusAfterProjectSwitch(_ project: String?, preferredPid: pid_t?, preferredWindowId: UInt32? = nil) -> Window? {
    if let project {
        let mru = projectMruWindowIds[project].flatMap { Window.get(byId: $0) }
        let candidates: [Window?] = if let preferredPid {
            [mru?.takeIf { $0.app.pid == preferredPid }] + Workspace.all.flatMap(\.allLeafWindowsRecursive).filter { $0.app.pid == preferredPid }
        } else {
            [mru]
        }
        let preferredWindow = preferredWindowId.flatMap { Window.get(byId: $0) }
        if let window = ([preferredWindow] + candidates).lazy.compactMap({ $0 })
            .first(where: { getWindowProjectName($0) == project && $0.isFocusableAfterProjectSwitch })
        {
            return window
        }
    }
    let workspace = focus.workspace
    let candidates: [Window?] = [workspace.mostRecentWindowRecursive, workspace.rootTilingContainer.mostRecentWindowRecursive] +
        workspace.allLeafWindowsRecursive
    return candidates.lazy.compactMap { $0 }.first(where: \.isFocusableAfterProjectSwitch)
}

extension Window {
    @MainActor var isFocusableAfterProjectSwitch: Bool {
        if projectHiddenPids.contains(app.pid) { return false }
        switch windowParentCases {
            case .tilingContainer, .floatingWindowsContainer: break
            case .macosHiddenAppsWindowsContainer, .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer, .unbound: return false
        }
        return toLiveFocusOrNil() != nil
    }
}

/// Should be called on every focus change
@MainActor func rememberProjectMruWindow(_ window: Window?) {
    guard let window, !config.projects.isEmpty else { return }
    if mruWindowIds.first != window.windowId {
        mruWindowIds = [window.windowId] + mruWindowIds.filter { $0 != window.windowId }.prefix(mruWindowIdsLimit - 1)
    }
    guard let project = getWindowProjectName(window) else { return }
    projectMruWindowIds[project] = window.windowId
}

@MainActor func onProjectChanged(prev: String?, new: String?) async {
    if !isUnitTest {
        ProjectToastPanel.shared.show(new ?? "No project", on: focus.workspace.workspaceMonitor)
    }
    broadcastEvent(.projectChanged(project: new, prevProject: prev))
    _ = await config.onProjectChanged.run(CmdEnv.defaultEnv.withEnvVars(getProjectChangedEnvVars(prev: prev, new: new)), CmdIoImpl.emptyStdinIgnoringOut)
}

func getProjectChangedEnvVars(prev: String?, new: String?) -> [String: String] {
    [AEROSPACE_PROJECT: new ?? "", AEROSPACE_PREV_PROJECT: prev ?? ""]
}

/// R4. A process of an inactive project got unhidden/activated externally (cmd-tab, Dock, notification click)
/// Returns true if the event was handled
@MainActor func handleInactiveProjectActivation(_ nsApp: NSRunningApplication, _ event: RefreshSessionEvent) async throws -> Bool {
    if config.projects.isEmpty || nsApp.activationPolicy != .regular { return false }
    // Our own hide/unhide calls trigger activations of other apps. Make the decision on the settled state
    while isProjectSwitchInProgress {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard let app = try await MacApp.getOrRegister(nsApp) else { return false }
    // Per-window processes are never hidden as a whole. Their windows are handled by handleInactiveProjectWindowActivation
    if isPerWindowProcess(app) { return false }
    guard let project = getProjectName(of: app), project != activeProjectName, !app.nsApp.isHidden else { return false }
    guard let token: RunSessionGuard = .isServerEnabled else { return false }
    try await runLightSession(event, token) {
        switch config.onInactiveProjectActivation {
            case ._switch:
                await switchProject(to: project, preferredPid: app.pid)
            case .rehide:
                await applyProjectVisibility(ProjectVisibilityPlan(toUnhide: [], toHide: [app.pid]))
                saveProjectState()
        }
    }
    return true
}

extension Ax {
    static let hiddenAttr = WritableAttrImpl<Bool>(
        key: kAXHiddenAttribute,
        getter: { $0 as? Bool },
        setter: { $0 as CFTypeRef },
    )
}
