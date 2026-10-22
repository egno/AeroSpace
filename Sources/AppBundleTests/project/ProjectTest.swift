@testable import AppBundle
import Common
import XCTest

@MainActor
final class ProjectTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    private func setUpProjectsConfig(_ toml: String = projectsTestConfig) {
        let result = parseConfig(toml)
        assertEquals(result.strErrors, [])
        config = result.config
        config.onProjectChanged = .empty
        resetProjectOwnershipCache()
    }

    private let annaChrome = TestProjectApp(pid: 101, bundleId: "com.google.Chrome", args: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --user-data-dir=/Users/me/.chrome/anna")
    private let bobChrome = TestProjectApp(pid: 102, bundleId: "com.google.Chrome", args: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --user-data-dir=/Users/me/.chrome/bob --flag")
    private let personalChrome = TestProjectApp(pid: 103, bundleId: "com.google.Chrome", args: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    private let annaKitty = TestProjectApp(pid: 104, bundleId: "net.kovidgoyal.kitty", args: "/Applications/kitty.app/Contents/MacOS/kitty --single-instance --instance-group anna herdr --session anna")
    private let annabelKitty = TestProjectApp(pid: 105, bundleId: "net.kovidgoyal.kitty", args: "kitty --instance-group annabel")
    private let firefox = TestProjectApp(pid: 106, bundleId: "org.mozilla.firefox", args: "/Applications/Firefox.app/Contents/MacOS/firefox")
    private let annaCursor = TestProjectApp(pid: 107, bundleId: "com.todesktop.230313mzl4w4u92", args: "Cursor --user-data-dir /Users/me/.cursor-projects/anna")
    private let slack = TestProjectApp(pid: 108, bundleId: "com.tinyspeck.slackmacgap", args: "Slack")

    func testOwnershipAndProjectSubstitution() {
        setUpProjectsConfig()
        assertEquals(getProjectOwnership(annaChrome), .project("anna"))
        assertEquals(getProjectOwnership(bobChrome), .project("bob"))
        assertEquals(getProjectOwnership(personalChrome), .global)
        assertEquals(getProjectOwnership(annaKitty), .project("anna"))
        assertEquals(getProjectOwnership(annabelKitty), .global) // `{project}( |$)` doesn't match prefixes
        assertEquals(getProjectOwnership(firefox), .project("company"))
        assertEquals(getProjectOwnership(annaCursor), .project("anna"))
        assertEquals(getProjectOwnership(slack), .global)
    }

    func testSharedMatchBeatsWholeAppMatch() {
        setUpProjectsConfig(
            """
            [project-apps.chrome]
            if = 'test %{app-bundle-id} = com.google.Chrome && test %{app-args} ~= " --user-data-dir=.*/{project}( |$)"'
            [project-apps.any-chrome]
            if = 'test %{app-bundle-id} = com.google.Chrome'

            [[projects]]
            name = 'anna'
            apps = ['chrome']

            [[projects]]
            name = 'company'
            apps = ['any-chrome']
            """,
        )
        assertEquals(getProjectOwnership(annaChrome), .project("anna"))
        assertEquals(getProjectOwnership(personalChrome), .project("company"))
        assertEquals(getProjectOwnership(bobChrome), .project("company"))
    }

    func testConflict() {
        setUpProjectsConfig(
            """
            [project-apps.chrome]
            if = 'test %{app-bundle-id} = com.google.Chrome'
            [project-apps.chromium-like]
            if = 'test %{app-name} ~= chrome'

            [[projects]]
            name = 'anna'
            apps = ['chrome']

            [[projects]]
            name = 'bob'
            apps = ['chromium-like']
            """,
        )
        assertEquals(getProjectOwnership(personalChrome), .conflict(["anna", "bob"]))
        assertNil(getProjectName(of: personalChrome))
        assertEquals(getProjectOwnershipConflictErrors(config.projects, [slack, personalChrome]), [
            "[ERROR] projects: Process 103 (com.google.Chrome) matches several projects with the same priority: anna, bob. The process is treated as global",
        ])
    }

    func testOwnershipIsCachedUntilReset() {
        setUpProjectsConfig()
        assertEquals(getProjectName(of: firefox), "company")
        config.projects = []
        config.projects = parseConfig(projectsTestConfig.replacingOccurrences(of: "'chrome', 'firefox',", with: "'chrome',")).config.projects
        assertEquals(getProjectName(of: firefox), "company") // cached
        resetProjectOwnershipCache()
        assertEquals(getProjectName(of: firefox), nil)
    }

    func testMatcherOperators() {
        func matches(_ raw: String, _ app: TestProjectApp) -> Bool {
            parseProjectAppMatcher(raw).getOrDie().matchesProjectApp(app)
        }
        assertTrue(matches("true", slack))
        assertFalse(matches("false", slack))
        assertTrue(matches("test %{app-pid} = 108", slack))
        assertTrue(matches("test-not %{app-pid} = 1", slack))
        assertTrue(matches("false || test %{app-name} ~= SLACK", slack))
        assertFalse(matches("true && test %{app-args} = foo", slack))
        assertFalse(matches("test %{app-pid} ~= 1", slack)) // Type error is a non-match
    }

    func testInterpolationVariables() {
        setUpProjectsConfig()
        assertPrimitiveString(FormatVar.app(.appArgs).expandFormatVar(obj: .app(slack)), .string("Slack"))
        assertPrimitiveString(FormatVar.app(.appProject).expandFormatVar(obj: .app(annaKitty)), .string("anna"))
        assertPrimitiveString(FormatVar.app(.appProject).expandFormatVar(obj: .app(slack)), .string(""))
        assertPrimitiveString(FormatVar.app(.appArgs).expandFormatVar(obj: .app(TestApp.shared)), .string("NULL-APP-ARGS"))
        let window = TestProjectWindow.new(id: 1, app: bobChrome, parent: focus.workspace.rootTilingContainer)
        let obj = AeroObj.window(.forTest(window: window, title: ""))
        assertPrimitiveString(FormatVar.window(.windowProject).expandFormatVar(obj: obj), .string("bob"))
        assertPrimitiveString(FormatVar.app(.appProject).expandFormatVar(obj: obj), .string("bob"))
    }

    private func assertPrimitiveString(_ actual: Result<Primitive, InterVarExpansionError>, _ expected: Primitive, file: StaticString = #filePath, line: UInt = #line) {
        assertEquals(actual.map { $0.toString() }.getOrNil(onFailure: { _ in }), expected.toString(), file: file, line: line)
    }

    func testVisibilityPlan() {
        let apps = [
            ProjectAppState(pid: 1, project: "anna", isHidden: true), // hidden by us -> unhide
            ProjectAppState(pid: 2, project: "anna", isHidden: true), // hidden by the user -> keep hidden
            ProjectAppState(pid: 3, project: "bob", isHidden: false), // -> hide
            ProjectAppState(pid: 4, project: "bob", isHidden: true), // hidden by the user -> don't claim
            ProjectAppState(pid: 5, project: nil, isHidden: false), // global -> never touched
            ProjectAppState(pid: 6, project: nil, isHidden: true), // global hidden by the user -> never touched
            ProjectAppState(pid: 7, project: nil, isHidden: true), // hidden by us, but the project is gone -> unhide
            ProjectAppState(pid: 8, project: "company", isHidden: true), // already hidden by us -> nothing
        ]
        assertEquals(
            getProjectVisibilityPlan(activeProject: "anna", apps: apps.reversed(), projectHiddenPids: [1, 7, 8]),
            ProjectVisibilityPlan(toUnhide: [1, 7], toHide: [3]),
        )
        assertEquals(
            getProjectVisibilityPlan(activeProject: nil, apps: apps, projectHiddenPids: [1, 7, 8]),
            ProjectVisibilityPlan(toUnhide: [7], toHide: [3]),
        )
        assertEquals(
            getProjectVisibilityPlan(activeProject: "bob", apps: apps, projectHiddenPids: [7]),
            ProjectVisibilityPlan(toUnhide: [7], toHide: []),
        )
    }

    func testAutoUnhideSkipsProjectHiddenApps() {
        projectHiddenPids = [2, 4]
        assertEquals(getPidsToAutoUnhide([1, 2, 3, 4]), [1, 3])
        projectHiddenPids = []
        assertEquals(getPidsToAutoUnhide([1, 2]), [1, 2])
    }

    func testFocusAfterSwitch_projectMruWindow() {
        setUpProjectsConfig()
        let root = focus.workspace.rootTilingContainer
        let annaWindow1 = TestProjectWindow.new(id: 1, app: annaChrome, parent: root)
        TestProjectWindow.new(id: 2, app: annaKitty, parent: root)
        let bobWindow = TestProjectWindow.new(id: 3, app: bobChrome, parent: root)
        let slackWindow = TestProjectWindow.new(id: 4, app: slack, parent: root)

        assertTrue(annaWindow1.focusWindow())
        assertTrue(slackWindow.focusWindow())
        rememberProjectMruWindow(annaWindow1)
        rememberProjectMruWindow(slackWindow) // global windows aren't remembered
        rememberProjectMruWindow(bobWindow)
        assertEquals(projectMruWindowIds, ["anna": 1, "bob": 3])

        projectHiddenPids = [bobChrome.pid]
        assertEquals(getFocusAfterProjectSwitch("anna", preferredPid: nil), annaWindow1)
        // preferredPid (the app activated from outside) wins over the MRU window
        assertEquals(getFocusAfterProjectSwitch("anna", preferredPid: annaKitty.pid)?.windowId, 2)
        // MRU window of the target is hidden -> the top window of the focused workspace
        assertEquals(getFocusAfterProjectSwitch("bob", preferredPid: nil), slackWindow)
        // No MRU window
        assertEquals(getFocusAfterProjectSwitch("company", preferredPid: nil), slackWindow)
    }

    func testFocusAfterSwitch_skipsHiddenAndFallsBackToEmptyWorkspace() {
        setUpProjectsConfig()
        let root = focus.workspace.rootTilingContainer
        let bobWindow = TestProjectWindow.new(id: 3, app: bobChrome, parent: root)
        assertTrue(bobWindow.focusWindow())
        projectHiddenPids = [bobChrome.pid]
        assertNil(getFocusAfterProjectSwitch(nil, preferredPid: nil))
        let annaWindow = TestProjectWindow.new(id: 1, app: annaChrome, parent: root)
        assertTrue(bobWindow.focusWindow())
        assertEquals(getFocusAfterProjectSwitch("anna", preferredPid: nil), annaWindow) // No MRU, but the workspace has a visible window
    }

    func testProjectCommand() async {
        setUpProjectsConfig()
        let root = focus.workspace.rootTilingContainer
        let annaWindow = TestProjectWindow.new(id: 1, app: annaChrome, parent: root)
        let bobWindow = TestProjectWindow.new(id: 2, app: bobChrome, parent: root)
        assertTrue(bobWindow.focusWindow())
        rememberProjectMruWindow(annaWindow)
        rememberProjectMruWindow(bobWindow)

        var result = await parseCommand("project anna").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(activeProjectName, "anna")
        assertEquals(focus.windowOrNil, annaWindow)

        result = await parseCommand("project bob").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(activeProjectName, "bob")
        assertEquals(focus.windowOrNil, bobWindow)

        result = await parseCommand("project-back-and-forth").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(activeProjectName, "anna")
        await parseCommand("project-back-and-forth").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(activeProjectName, "bob")

        await parseCommand("project --none").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(activeProjectName, nil)
        await parseCommand("project-back-and-forth").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(activeProjectName, "bob")
        await parseCommand("project-back-and-forth").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(activeProjectName, nil)

        result = await parseCommand("project dave").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, ["Unknown project 'dave'. Configured projects: anna, bob, company"])
        assertEquals(activeProjectName, nil)
    }

    func testProjectBackAndForthWithoutHistory() async {
        setUpProjectsConfig()
        let result = await parseCommand("project-back-and-forth").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, ["No previously active project"])
    }

    func testProjectCommandWithoutProjects() async {
        let result = await parseCommand("project next").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, ["No projects are configured. Please declare [[projects]] in the config"])
        assertEquals(activeProjectName, nil)
    }

    func testProjectNextPrev() async {
        setUpProjectsConfig()
        await parseCommand("project next").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(activeProjectName, "anna")
        await parseCommand("project next").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(activeProjectName, "bob")
        await parseCommand("project next").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(activeProjectName, "company")
        let result = await parseCommand("project next").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, ["Reached the end of the projects list"])
        await parseCommand("project next --wrap-around").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(activeProjectName, "anna")
        await parseCommand("project prev --wrap-around").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(activeProjectName, "company")
        await parseCommand("project prev").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(activeProjectName, "bob")

        assertEquals(getNextPrevProject(["a", "b"], current: nil, .prev, wrapAround: false), .success("b"))
        assertEquals(getNextPrevProject(["a", "b"], current: "a", .prev, wrapAround: false), .failure("Reached the beginning of the projects list"))
        assertEquals(getNextPrevProject([], current: nil, .next, wrapAround: true), .failure("The list of projects is empty"))
    }

    func testProjectFilterAndListProjects() async {
        setUpProjectsConfig()
        activeProjectName = "anna"
        assertTrue(ProjectFilter.name("bob").matches(bobChrome))
        assertFalse(ProjectFilter.name("bob").matches(annaChrome))
        assertTrue(ProjectFilter.global.matches(slack))
        assertFalse(ProjectFilter.global.matches(annaChrome))
        assertTrue(ProjectFilter.active.matches(annaKitty))
        assertFalse(ProjectFilter.active.matches(slack))
        activeProjectName = nil
        assertFalse(ProjectFilter.active.matches(slack))

        activeProjectName = "bob"
        let infos = getProjectInfos(apps: [annaChrome, annaKitty, bobChrome, slack, firefox])
        let list = infos.map(AeroObj.project)
        assertSucc(
            list.format(ListProjectsCmdArgs(rawArgs: []).format),
            ["anna    | false | chrome kitty", "bob     | true  | chrome", "company | false | firefox"],
        )
        assertSucc(
            list.formatToJson([.interVar(.formatVar(.project(.projectName))), .interVar(.formatVar(.project(.projectApps)))], ignoreRightPaddingVar: false),
            """
            [
              {
                "project-apps" : "chrome kitty cursor",
                "project-name" : "anna"
              },
              {
                "project-apps" : "chrome kitty cursor",
                "project-name" : "bob"
              },
              {
                "project-apps" : "chrome firefox kitty cursor",
                "project-name" : "company"
              }
            ]
            """,
        )
    }

    func testListWindowsProjectFilter() async {
        setUpProjectsConfig()
        let root = focus.workspace.rootTilingContainer
        TestProjectWindow.new(id: 1, app: annaChrome, parent: root)
        TestProjectWindow.new(id: 2, app: bobChrome, parent: root)
        TestProjectWindow.new(id: 3, app: slack, parent: root)
        activeProjectName = "bob"
        func windowIds(_ cmd: String) async -> [String] {
            await parseCommand(cmd + " --format %{window-id}").cmdOrDie.run(.defaultEnv, .emptyStdin).stdout.sorted()
        }
        assertEquals(await windowIds("list-windows --monitor all --project anna"), ["1"])
        assertEquals(await windowIds("list-windows --monitor all --project --active"), ["2"])
        assertEquals(await windowIds("list-windows --monitor all --project --none"), ["3"])
    }

    func testProcArgs() {
        var buffer: [UInt8] = [3, 0, 0, 0] // argc = 3
        buffer += Array("/bin/exe".utf8) + [0, 0, 0, 0]
        buffer += Array("exe".utf8) + [0] + Array("--instance-group".utf8) + [0] + Array("anna".utf8) + [0]
        buffer += Array("HOME=/Users/me".utf8) + [0]
        assertEquals(parseProcArgs2(buffer), "exe --instance-group anna")
        assertNil(parseProcArgs2([1, 0]))
        assertTrue(getProcessArgs(pid: getpid())?.isEmpty == false)
    }
}
