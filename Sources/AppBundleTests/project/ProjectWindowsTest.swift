@testable import AppBundle
import Common
import XCTest

let perWindowProjectsTestConfig = """
    config-version = 2

    [project-apps.chrome] # One personal Chrome shared by all projects. Windows are named after projects
    if = 'test %{app-bundle-id} = com.google.Chrome && test-not %{app-args} ~= -- "--user-data-dir"'
    window-if = 'test %{window-title} ~= "^{project} - Google Chrome$"'
    new-windows = 'active-project'
    on-window-assigned = 'exec-and-forget osascript -e "tell application id \\"com.google.Chrome\\" to set given name of window 1 to \\"$AEROSPACE_PROJECT\\""'
    launch = 'open -na "Google Chrome" --args --new-window'
    bundle-id = 'com.google.Chrome'

    [project-apps.kitty]
    if = 'test %{app-bundle-id} = net.kovidgoyal.kitty && test %{app-args} ~= " --instance-group[= ]{project}( |$)"'
    launch = 'kitty --single-instance --instance-group {project}'

    [[projects]]
    name = 'anna'
    apps = ['chrome', 'kitty']

    [[projects]]
    name = 'bob'
    apps = ['chrome', 'kitty']

    [[projects]]
    name = 'company'
    apps = ['kitty']
    """

@MainActor
final class ProjectWindowsTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    private func setUpProjectsConfig(_ toml: String = perWindowProjectsTestConfig) {
        let result = parseConfig(toml)
        assertEquals(result.strErrors, [])
        config = result.config
        config.onProjectChanged = .empty
        resetProjectOwnershipCache()
        runningAppsForTests = [chrome, annaKitty, slack]
    }

    @discardableResult
    private func run(_ command: String) async -> CmdResult {
        await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
    }

    private let chrome = TestProjectApp(pid: 103, bundleId: "com.google.Chrome", args: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    private let annaChrome = TestProjectApp(pid: 101, bundleId: "com.google.Chrome", args: "Google Chrome --user-data-dir=/Users/me/.chrome/anna")
    private let annaKitty = TestProjectApp(pid: 104, bundleId: "net.kovidgoyal.kitty", args: "kitty --single-instance --instance-group anna")
    private let slack = TestProjectApp(pid: 108, bundleId: "com.tinyspeck.slackmacgap", args: "Slack")

    @discardableResult
    private func chromeWindow(_ id: UInt32, _ title: String, parent: NonLeafTreeNodeObject, weight: CGFloat = 1) -> TestProjectWindow {
        TestProjectWindow.new(id: id, app: chrome, parent: parent, adaptiveWeight: weight, title: title + " - Google Chrome")
    }

    private func windowAssigned(_ window: Window, _ project: String) -> ProjectSideEffect {
        .windowAssigned(windowId: window.windowId, env: [AEROSPACE_PROJECT: project, AEROSPACE_WINDOW_ID: window.windowId.description])
    }

    func testConfig() {
        setUpProjectsConfig()
        assertTrue(config.projectApps["chrome"]?.isPerWindow == true)
        assertEquals(config.projectApps["chrome"]?.newWindows, .activeProject)
        assertTrue(config.projectApps["chrome"]?.onWindowAssigned.flatten().singleOrNil() is ExecAndForgetCommand)
        assertTrue(config.projects[0].apps[0].isPerWindow)
        assertFalse(config.projects[0].apps[1].isPerWindow)
        assertEquals(config.projectApps["kitty"]?.newWindows, .global)

        let errors = parseConfig(
            """
            [project-apps.a]
            if = 'true'
            new-windows = 'active-project'
            on-window-assigned = 'true'
            [project-apps.b]
            if = 'true'
            window-if = 'test %{workspace} = x'
            new-windows = 'foo'
            [project-apps.c]
            if = 'true'
            window-if = 'test %{window-project} = x'
            [project-apps.d]
            if = 'test %{window-title} = x'
            [[projects]]
            name = 'anna'
            apps = ['a', 'b', 'c', 'd']
            [[projects]]
            name = 'bob'
            apps = ['a', 'b', 'c']
            """,
        ).strErrors
        // A per-window definition (b, c) may be referenced by several projects, unlike a whole-app definition (a)
        assertEquals(errors.sorted(), [
            "[ERROR] project-apps.a.new-windows: 'new-windows' requires 'window-if'",
            "[ERROR] project-apps.a.on-window-assigned: 'on-window-assigned' requires 'window-if'",
            "[ERROR] project-apps.a: Whole-app definition 'a' (its 'if' doesn't contain {project}) is referenced by several projects: anna, bob. A whole-app definition can be referenced only by a single project",
            "[ERROR] project-apps.b.new-windows: Can't parse 'foo'.\nPossible values: (active-project|global)",
            "[ERROR] project-apps.b.window-if: Only %{app-*} and %{window-*} interpolation variables are allowed in 'window-if'. Got: %{workspace}",
            "[ERROR] project-apps.c.window-if: %{window-project} is not allowed in project app matchers",
            "[ERROR] project-apps.d.if: Only %{app-*} interpolation variables are allowed in project app matchers. Got: %{window-title}",
        ])
    }

    func testOwnershipPrecedence() async throws {
        setUpProjectsConfig()
        let root = focus.workspace.rootTilingContainer
        let annaWindow = chromeWindow(1, "anna", parent: root)
        let bobWindow = chromeWindow(2, "bob", parent: root)
        let unnamedWindow = chromeWindow(3, "Inbox", parent: root)
        let annabelWindow = chromeWindow(4, "annabel", parent: root) // `^{project} - ` doesn't match prefixes
        let annaChromeWindow = TestProjectWindow.new(id: 5, app: annaChrome, parent: root, title: "bob - Google Chrome")
        try await refreshWindowIfOwnership(.nonCancellable)

        assertTrue(isPerWindowProcess(chrome))
        assertFalse(isPerWindowProcess(annaChrome)) // Doesn't match per-window `if`
        assertEquals(getProjectOwnership(chrome), .global) // Per-window definitions don't own processes
        assertEquals(getWindowProjectName(annaWindow), "anna")
        assertEquals(getWindowProjectName(bobWindow), "bob")
        assertNil(getWindowProjectName(unnamedWindow))
        assertNil(getWindowProjectName(annabelWindow))
        assertNil(getWindowProjectName(annaChromeWindow)) // window-if applies only to processes matched by `if`

        let obj = AeroObj.window(.forTest(window: annaWindow, title: ""))
        assertEquals(FormatVar.window(.windowProject).expandFormatVar(obj: obj).getOrNil(onFailure: { _ in })?.toString(), "anna")
        assertEquals(FormatVar.app(.appProject).expandFormatVar(obj: obj).getOrNil(onFailure: { _ in })?.toString(), "")
        assertTrue(ProjectFilter.name("anna").matches(window: annaWindow))
        assertTrue(ProjectFilter.global.matches(window: unnamedWindow))
        assertEquals(getProjectInfos(apps: runningAppsForTests).map(\.runningAppIds), [["chrome", "kitty"], ["chrome"], []])

        // Manual override > window-if
        setWindowOwnershipOverride(annaWindow, project: "bob")
        setWindowOwnershipOverride(unnamedWindow, project: "anna")
        assertEquals(getWindowProjectName(annaWindow), "bob")
        assertEquals(getWindowProjectName(unnamedWindow), "anna")
        setWindowOwnershipOverride(bobWindow, project: nil)
        assertNil(getWindowProjectName(bobWindow))

        // window-if > process ownership
        setProjectOwnershipOverride(pid: chrome.pid, project: "company")
        assertEquals(getWindowProjectName(annabelWindow), "company")
        windowOwnershipOverrides = [:]
        assertEquals(getWindowProjectName(annaWindow), "anna")

        // Titles change
        annaWindow.title = "bob - Google Chrome"
        try await refreshWindowIfOwnership(.nonCancellable)
        assertEquals(getWindowProjectName(annaWindow), "bob")
    }

    func testProcessLevelHidingSkipsPerWindowProcesses() {
        setUpProjectsConfig()
        assertEquals(getProjectAppState(chrome, isHidden: false), ProjectAppState(pid: chrome.pid, project: nil, isHidden: false))
        assertEquals(getProjectAppState(annaKitty, isHidden: false), ProjectAppState(pid: annaKitty.pid, project: "anna", isHidden: false))
        // Even if the whole process is moved to a project, it's hidden window by window
        setProjectOwnershipOverride(pid: chrome.pid, project: "bob")
        let states = [getProjectAppState(chrome, isHidden: false), getProjectAppState(annaKitty, isHidden: false)]
        assertEquals(getProjectVisibilityPlan(activeProject: "anna", apps: states, projectHiddenPids: []), ProjectVisibilityPlan())
        // A per-window process that AeroSpace hid earlier (e.g. before the config change) gets unhidden
        assertEquals(getProjectVisibilityPlan(activeProject: "anna", apps: states, projectHiddenPids: [chrome.pid]), ProjectVisibilityPlan(toUnhide: [chrome.pid]))
    }

    func testHideAndRestoreAtExactPosition() async throws {
        setUpProjectsConfig()
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        TestProjectWindow.new(id: 1, app: slack, parent: root, adaptiveWeight: 1)
        let anna1 = chromeWindow(2, "anna", parent: root, weight: 2)
        let bob = chromeWindow(3, "bob", parent: root, weight: 3)
        let anna2 = chromeWindow(4, "anna", parent: root, weight: 4)
        chromeWindow(5, "Inbox", parent: root, weight: 5)
        let annaFloating = chromeWindow(6, "anna", parent: workspace.floatingWindowsContainer)
        try await refreshWindowIfOwnership(.nonCancellable)
        assertTrue(anna2.focusWindow())
        rememberProjectMruWindow(anna2)
        let all: LayoutDescription = .h_tiles([.window(1), .window(2), .window(3), .window(4), .window(5)])

        await run("project anna")
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .window(4), .window(5)]))
        assertTrue(bob.parent === workspace.macOsNativeHiddenAppsWindowsContainer)
        assertTrue(bob.isParkedByProject)
        assertFalse(bob.isFocusableAfterProjectSwitch)
        assertEquals(projectHiddenPids, []) // The process is never hidden
        assertEquals(focus.windowOrNil, anna2)

        await run("project bob")
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(3), .window(5)]))
        assertEquals(focus.windowOrNil, bob)
        assertEquals(Set(projectHiddenWindows.keys), [anna1.windowId, anna2.windowId, annaFloating.windowId])
        assertTrue(annaFloating.isParkedByProject)

        await run("project --none")
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(5)]))

        await run("project anna")
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .window(4), .window(5)]))
        assertEquals(focus.windowOrNil, anna2)
        assertTrue(annaFloating.parent === workspace.floatingWindowsContainer)

        await run("project bob")
        await run("project anna")
        await run("project-back-and-forth")
        await run("project-back-and-forth")
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .window(4), .window(5)]))

        // Every window is back at its exact place
        windowOwnershipOverrides[bob.windowId] = WindowOwnershipOverride(pid: chrome.pid, project: "anna")
        await reapplyProjectVisibility()
        assertEquals(root.layoutDescription, all)
        assertEquals(root.children.map { $0.getWeight(.h) }, [1, 2, 3, 4, 5])
        assertEquals(projectHiddenWindows, [:])
    }

    func testHiddenWindowsKeepTheirWorkspace() async {
        setUpProjectsConfig()
        activeProjectName = "anna"
        let workspaceB = Workspace.get(byName: "B")
        let bob = chromeWindow(1, "bob", parent: workspaceB.rootTilingContainer)
        await reapplyProjectVisibility()
        assertTrue(bob.isParkedByProject)
        Workspace.garbageCollectUnusedWorkspaces()
        assertTrue(Workspace.all.contains(workspaceB)) // Not garbage collected
        assertTrue(bob.nodeWorkspace === workspaceB) // Moving the workspace to another monitor carries the window

        // `enable off` brings the windows back
        TrayMenuModel.shared.isEnabled = false
        defer { TrayMenuModel.shared.isEnabled = true }
        await unhideAllProjectHiddenApps()
        assertEquals(workspaceB.rootTilingContainer.layoutDescription, .h_tiles([.window(1)]))
        assertEquals(projectHiddenWindows, [:])
    }

    func testUnminimizedWindowOfInactiveProjectStaysHidden() async throws {
        setUpProjectsConfig()
        activeProjectName = "anna"
        let root = focus.workspace.rootTilingContainer
        chromeWindow(1, "Inbox", parent: root)
        let bob = chromeWindow(2, "bob", parent: root)
        bob.layoutReason = .macos(prevParentKind: .tilingContainer)
        bob.prevTilingBinding = PrevTilingBinding(bob.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST))
        try await normalizeLayoutReason() // Not minimized anymore, but owned by inactive project
        assertTrue(bob.isParkedByProject)
        activeProjectName = "bob"
        try await normalizeLayoutReason()
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }

    func testNewWindowAssignment() async {
        setUpProjectsConfig()
        let root = focus.workspace.rootTilingContainer

        // No active project -> global
        let window1 = chromeWindow(1, "New Tab", parent: root)
        await assignNewProjectWindowIfNeeded(window1)
        assertNil(getWindowProjectName(window1))
        assertEquals(projectSideEffectsForTests, [])

        // Active project -> the window is assigned to it and on-window-assigned runs
        activeProjectName = "anna"
        let window2 = chromeWindow(2, "New Tab", parent: root)
        await assignNewProjectWindowIfNeeded(window2)
        assertEquals(windowOwnershipOverrides[window2.windowId], WindowOwnershipOverride(pid: chrome.pid, project: "anna"))
        assertEquals(projectSideEffectsForTests, [windowAssigned(window2, "anna")])
        assertFalse(window2.isParkedByProject)

        // window-if already decides
        projectSideEffectsForTests = []
        let window3 = chromeWindow(3, "bob", parent: root)
        await assignNewProjectWindowIfNeeded(window3)
        assertNil(windowOwnershipOverrides[window3.windowId])
        assertEquals(getWindowProjectName(window3), "bob")

        // Not a per-window app
        let kittyWindow = TestProjectWindow.new(id: 4, app: annaKitty, parent: root)
        await assignNewProjectWindowIfNeeded(kittyWindow)
        assertNil(windowOwnershipOverrides[kittyWindow.windowId])

        // The active project doesn't reference the per-window app
        activeProjectName = "company"
        let window5 = chromeWindow(5, "New Tab", parent: root)
        await assignNewProjectWindowIfNeeded(window5)
        assertNil(windowOwnershipOverrides[window5.windowId])
        assertEquals(projectSideEffectsForTests, [])

        // new-windows = 'global'
        setUpProjectsConfig(perWindowProjectsTestConfig.replacingOccurrences(of: "new-windows = 'active-project'", with: "new-windows = 'global'"))
        activeProjectName = "anna"
        let window6 = chromeWindow(6, "New Tab", parent: root)
        await assignNewProjectWindowIfNeeded(window6)
        assertNil(getWindowProjectName(window6))
    }

    func testProjectLaunch() async throws {
        setUpProjectsConfig()
        activeProjectName = "anna"
        let root = focus.workspace.rootTilingContainer
        let anna1 = chromeWindow(1, "anna", parent: root)
        let anna2 = chromeWindow(2, "anna", parent: root)
        let bob = chromeWindow(3, "bob", parent: root)
        let slackWindow = TestProjectWindow.new(id: 4, app: slack, parent: root)
        try await refreshWindowIfOwnership(.nonCancellable)
        for window in [anna2, anna1, slackWindow] {
            assertTrue(window.focusWindow())
            rememberProjectMruWindow(window)
        }
        await reapplyProjectVisibility()
        assertTrue(bob.isParkedByProject)

        // Launch or focus: the project's MRU window of the app
        var result = await run("project-launch --app chrome")
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(focus.windowOrNil, anna1)
        assertEquals(projectSideEffectsForTests, [])

        // Inactive project -> switch to it, focusing its window
        result = await run("project-launch --project bob --app chrome")
        assertEquals(activeProjectName, "bob")
        assertEquals(focus.windowOrNil, bob)
        assertTrue(anna1.isParkedByProject)

        // The project has no windows of the app -> open a new one. It goes to the project even if it's not active
        activeProjectName = "anna"
        await reapplyProjectVisibility()
        bob.unbindFromParent()
        result = await run("project-launch --project bob --app chrome")
        assertEquals(projectSideEffectsForTests, [.launch(script: "open -na \"Google Chrome\" --args --new-window", env: [AEROSPACE_PROJECT: "bob"])])
        assertEquals(pendingProjectWindowAssignments.map(\.project), ["bob"])
        projectSideEffectsForTests = []
        let newWindow = chromeWindow(5, "New Tab", parent: root)
        await assignNewProjectWindowIfNeeded(newWindow)
        assertEquals(getWindowProjectName(newWindow), "bob")
        assertEquals(projectSideEffectsForTests, [windowAssigned(newWindow, "bob")])
        assertTrue(newWindow.isParkedByProject)
        assertEquals(pendingProjectWindowAssignments, [])

        // project --launch-missing: per-window apps are "missing" if the project has no windows of them
        projectSideEffectsForTests = []
        newWindow.unbindFromParent()
        result = await run("project bob --launch-missing")
        assertEquals(projectSideEffectsForTests, [
            .launch(script: "open -na \"Google Chrome\" --args --new-window", env: [AEROSPACE_PROJECT: "bob"]),
            .launch(script: "kitty --single-instance --instance-group bob", env: [AEROSPACE_PROJECT: "bob"]),
        ])
    }

    func testInactiveProjectWindowActivation() async {
        setUpProjectsConfig()
        activeProjectName = "anna"
        let root = focus.workspace.rootTilingContainer
        let anna = chromeWindow(9001, "anna", parent: root)
        let bob = chromeWindow(9002, "bob", parent: root)
        assertTrue(anna.focusWindow())
        await reapplyProjectVisibility()
        assertTrue(bob.isParkedByProject)

        // AeroSpace itself focused the window right before hiding it
        assertTrue(await handleInactiveProjectWindowActivation(bob))
        assertEquals(activeProjectName, "anna")
        // The same native focus isn't handled twice
        projectHiddenWindows[bob.windowId] = .distantPast
        assertFalse(await handleInactiveProjectWindowActivation(bob))
        assertFalse(await handleInactiveProjectWindowActivation(anna)) // Visible window
        assertEquals(activeProjectName, "anna")

        // rehide
        markNativeFocusAsSeen(anna)
        config.onInactiveProjectActivation = .rehide
        assertTrue(await handleInactiveProjectWindowActivation(bob))
        assertEquals(activeProjectName, "anna")
        assertEquals(focus.windowOrNil, anna)
        assertTrue(bob.isParkedByProject)

        // switch
        markNativeFocusAsSeen(anna)
        config.onInactiveProjectActivation = ._switch
        assertFalse(await handleInactiveProjectWindowActivation(bob))
        assertEquals(activeProjectName, "bob")
        assertEquals(focus.windowOrNil, bob)
        assertEquals(root.layoutDescription, .h_tiles([.window(9002)]))
    }

    func testMoveWindowToProjectCommand() async throws {
        assertEquals(parseCommand("move-window-to-project").errorOrNil, "Either <project-name> or --none must be specified")
        assertEquals(parseCommand("move-window-to-project --none anna").errorOrNil, "--none is incompatible with <project-name>")
        assertNil(parseCommand("move-window-to-project anna --window-id 1").errorOrNil)

        var result = await run("move-window-to-project anna")
        assertEquals(result.stderr, ["No projects are configured. Please declare [[projects]] in the config"])

        setUpProjectsConfig()
        activeProjectName = "anna"
        let root = focus.workspace.rootTilingContainer
        let anna = chromeWindow(1, "anna", parent: root)
        let unnamed = chromeWindow(2, "Inbox", parent: root)
        TestProjectWindow.new(id: 3, app: annaKitty, parent: root)
        try await refreshWindowIfOwnership(.nonCancellable)
        rememberProjectMruWindow(anna)
        assertTrue(unnamed.focusWindow())

        result = await run("move-window-to-project dave")
        assertEquals(result.stderr, ["Unknown project 'dave'. Configured projects: anna, bob, company"])
        result = await run("move-window-to-project --window-id 3 bob")
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, ["Window 3 doesn't belong to a per-window app ([project-apps.<id>] with 'window-if'). Use move-app-to-project to move the whole process"])

        // The focused window goes to the inactive project: it's hidden and the focus moves on
        result = await run("move-window-to-project bob")
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(getWindowProjectName(unnamed), "bob")
        assertEquals(projectSideEffectsForTests, [windowAssigned(unnamed, "bob")])
        assertTrue(unnamed.isParkedByProject)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(3)]))
        assertEquals(focus.windowOrNil, anna)

        // --window-id. The hidden window comes back to its place. The focus stays
        projectSideEffectsForTests = []
        result = await run("move-window-to-project --window-id 2 --none")
        assertEquals(result.exitCode.rawValue, 0)
        assertNil(getWindowProjectName(unnamed))
        assertEquals(windowOwnershipOverrides[unnamed.windowId], WindowOwnershipOverride(pid: chrome.pid, project: nil))
        assertEquals(projectSideEffectsForTests, [windowAssigned(unnamed, "")])
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .window(3)]))
        assertEquals(focus.windowOrNil, anna)

        // The override beats window-if
        result = await run("move-window-to-project --window-id 1 bob")
        assertTrue(anna.isParkedByProject)
        assertEquals(getWindowProjectName(anna), "bob")
    }

    func testStatePersistence() async throws {
        setUpProjectsConfig()
        let root = focus.workspace.rootTilingContainer
        let window1 = chromeWindow(1, "Inbox", parent: root)
        let window2 = chromeWindow(2, "Inbox", parent: root)
        let window3 = chromeWindow(3, "Inbox", parent: root)
        setWindowOwnershipOverride(window1, project: "bob")
        setWindowOwnershipOverride(window2, project: nil)
        setWindowOwnershipOverride(window3, project: "anna")
        windowOwnershipOverrides[999] = WindowOwnershipOverride(pid: chrome.pid, project: "anna") // The window is gone

        let data = try JSONEncoder.aeroSpaceDefault.encode(getProjectStateFile())
        let state = try JSONDecoder().decode(ProjectStateFile.self, from: data)
        assertEquals(state.windowOwnershipOverrides?.map(\.windowId), [1, 2, 3, 999])
        assertEquals(state.windowOwnershipOverrides?.first?.args, chrome.args)

        windowOwnershipOverrides = [:]
        window3.unbindFromParent()
        restoreWindowOwnershipOverrides(state)
        assertEquals(windowOwnershipOverrides, [
            1: WindowOwnershipOverride(pid: chrome.pid, project: "bob"),
            2: WindowOwnershipOverride(pid: chrome.pid, project: nil),
        ])

        // The process was restarted with the same pid (e.g. after reboot): argv differs
        windowOwnershipOverrides = [:]
        runningAppsForTests = [TestProjectApp(pid: chrome.pid, bundleId: "com.google.Chrome", args: "other")]
        restoreWindowOwnershipOverrides(state)
        assertEquals(windowOwnershipOverrides, [:])

        // Overrides of exited processes are dropped
        runningAppsForTests = [chrome]
        setWindowOwnershipOverride(window1, project: "bob")
        runningAppsForTests = []
        await reapplyProjectVisibility()
        assertEquals(windowOwnershipOverrides, [:])
    }
}
