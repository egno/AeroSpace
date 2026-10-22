@testable import AppBundle
import Common
import XCTest

@MainActor
final class ProjectLifecycleTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    private func setUpProjectsConfig(_ toml: String = projectsTestConfig) {
        let result = parseConfig(toml)
        assertEquals(result.strErrors, [])
        config = result.config
        config.onProjectChanged = .empty
        resetProjectOwnershipCache()
    }

    private func parseArgs<T: CmdArgs>(_ raw: String, as _: T.Type) -> T? {
        parseCommand(raw).cmdOrNil?.flatten().singleOrNil()?.args as? T
    }

    private func run(_ command: String) async -> CmdResult {
        await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
    }

    private let annaChrome = TestProjectApp(pid: 101, bundleId: "com.google.Chrome", args: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --user-data-dir=/Users/me/.chrome/anna")
    private let bobChrome = TestProjectApp(pid: 102, bundleId: "com.google.Chrome", args: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --user-data-dir=/Users/me/.chrome/bob --flag")
    private let personalChrome = TestProjectApp(pid: 103, bundleId: "com.google.Chrome", args: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    private let annaKitty = TestProjectApp(pid: 104, bundleId: "net.kovidgoyal.kitty", args: "/Applications/kitty.app/Contents/MacOS/kitty --single-instance --instance-group anna herdr --session anna")
    private let slack = TestProjectApp(pid: 108, bundleId: "com.tinyspeck.slackmacgap", args: "Slack")

    private func launch(_ script: String, _ project: String) -> ProjectSideEffect {
        .launch(script: script, env: [AEROSPACE_PROJECT: project])
    }

    private var annaCursorLaunch: ProjectSideEffect {
        launch("cursor --user-data-dir ~/.cursor-projects/anna '\(homeDirPath)/src/anna-api' '\(homeDirPath)/src/anna-web'", "anna")
    }

    func testParse() {
        assertNil(parseCommand("project-launch").errorOrNil)
        // exec-and-forget is recognized only at the beginning. The documented fallback runs the chain in bash
        assertEquals(parseCommand("project-launch --app kitty || exec-and-forget open -na kitty").errorOrNil, "Unrecognized subcommand 'exec-and-forget'")
        assertNil(parseCommand("exec-and-forget aerospace project-launch --app kitty || open -na kitty").errorOrNil)
        assertEquals(parseArgs("project-launch --app kitty chrome", as: ProjectLaunchCmdArgs.self), ProjectLaunchCmdArgs(rawArgs: []).copy(\.appIds, ["kitty", "chrome"]))
        assertEquals(parseArgs("project-launch --project anna --app cursor --open '~/a' '~/b'", as: ProjectLaunchCmdArgs.self)?.open, ["~/a", "~/b"])
        assertEquals(parseCommand("project-launch --open /a").errorOrNil, "--open requires exactly one <app-id> in --app")
        assertEquals(parseCommand("project-launch --app a b --open /a").errorOrNil, "--open requires exactly one <app-id> in --app")
        assertEquals(parseCommand("project-launch --app a a").errorOrNil, "Duplicated <app-id> in --app")
        assertEquals(parseCommand("project-launch --app").errorOrNil, "ERROR: '--app' must be followed by '<app-id>...'")
        assertEquals(parseCommand("project-launch --project Anna").errorOrNil, "ERROR: Failed to parse 'Anna' CLI argument: Project name 'Anna' must match [a-z0-9_-]+ regex")

        assertNil(parseCommand("project-quit").errorOrNil)
        assertEquals(parseArgs("project-quit anna", as: ProjectQuitCmdArgs.self)?.project, "anna")

        assertEquals(parseCommand("move-app-to-project").errorOrNil, "Either <project-name> or --none must be specified")
        assertEquals(parseCommand("move-app-to-project --none anna").errorOrNil, "--none is incompatible with <project-name>")
        assertEquals(parseArgs("move-app-to-project anna --pid 12", as: MoveAppToProjectCmdArgs.self)?.pid, 12)

        assertNil(parseCommand("project anna --launch-missing").errorOrNil)
        assertNil(parseCommand("project next --wrap-around --launch-missing").errorOrNil)
        assertEquals(parseCommand("project --none --launch-missing").errorOrNil, "ERROR: Conflicting options: --launch-missing, --none")
    }

    func testOpenSubstitution() {
        assertSucc(substituteOpenPlaceholder("cursor {open}", ["~/src/a b", "it's", "~", "/x~"], home: "/Users/me"),
                   "cursor '/Users/me/src/a b' 'it'\\''s' '/Users/me' '/x~'")
        assertSucc(substituteOpenPlaceholder("cursor {open} --new", [], home: "/h"), "cursor  --new")
        assertSucc(substituteOpenPlaceholder("open -a Firefox", [], home: "/h"), "open -a Firefox")
        assertEquals(
            substituteOpenPlaceholder("open -a Firefox", ["x"], home: "/h"),
            .failure("The launch command doesn't contain {open} placeholder. Items to open can't be passed: open -a Firefox"),
        )
        assertEquals("a'b".shellQuoted, "'a'\\''b'")
    }

    func testLaunchVsFocus() async {
        setUpProjectsConfig()
        activeProjectName = "anna"
        runningAppsForTests = [annaChrome, annaKitty, bobChrome, slack]
        let root = focus.workspace.rootTilingContainer
        let chromeWindow = TestProjectWindow.new(id: 1, app: annaChrome, parent: root)
        let kittyWindow1 = TestProjectWindow.new(id: 2, app: annaKitty, parent: root)
        let kittyWindow2 = TestProjectWindow.new(id: 3, app: annaKitty, parent: root)
        let slackWindow = TestProjectWindow.new(id: 4, app: slack, parent: root)
        for window in [kittyWindow2, kittyWindow1, slackWindow] {
            assertTrue(window.focusWindow())
            rememberProjectMruWindow(window)
        }

        // Running -> focus the MRU window of the instance
        var result = await run("project-launch --app kitty")
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(focus.windowOrNil, kittyWindow1)
        result = await run("project-launch --app chrome")
        assertEquals(focus.windowOrNil, chromeWindow)
        assertEquals(projectSideEffectsForTests, [])

        // Not running -> launch with the project's `open` items
        result = await run("project-launch --app cursor")
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(projectSideEffectsForTests, [annaCursorLaunch])

        // --open -> launch even if running. Only --open items are passed
        projectSideEffectsForTests = []
        runningAppsForTests.append(TestProjectApp(pid: 107, bundleId: "com.todesktop.230313mzl4w4u92", args: "Cursor --user-data-dir /Users/me/.cursor-projects/anna"))
        result = await run("project-launch --app cursor --open /src/third")
        assertEquals(projectSideEffectsForTests, [launch("cursor --user-data-dir ~/.cursor-projects/anna '/src/third'", "anna")])

        // Running, but no windows to focus -> launch
        projectSideEffectsForTests = []
        assertTrue(slackWindow.focusWindow())
        chromeWindow.unbindFromParent()
        result = await run("project-launch --app chrome")
        assertEquals(projectSideEffectsForTests, [launch("open -na \"Google Chrome\" --args --user-data-dir=\"$HOME/.chrome/anna\"", "anna")])

        // --open with a launch command without {open}
        projectSideEffectsForTests = []
        result = await run("project-launch --app chrome --open x")
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, [
            "App 'chrome': The launch command doesn't contain {open} placeholder. Items to open can't be passed: open -na \"Google Chrome\" --args --user-data-dir=\"$HOME/.chrome/anna\"",
        ])
        assertEquals(projectSideEffectsForTests, [])
    }

    func testLaunchNotReferencedApp() async {
        setUpProjectsConfig()
        activeProjectName = "anna"
        let result = await run("project-launch --project anna --app kitty firefox")
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, ["Project 'anna' doesn't reference app 'firefox'"])
        assertEquals(projectSideEffectsForTests, []) // All or nothing

        // Without --project, apps that the active project doesn't reference target their global instances
        let implicit = await run("project-launch --app kitty firefox")
        assertEquals(implicit.stderr, ["App 'firefox' has no 'bundle-id'. It's required to find the global instance"])
        assertEquals(projectSideEffectsForTests, []) // All or nothing

        let unknown = await run("project-launch --project dave")
        assertEquals(unknown.stderr, ["Unknown project 'dave'. Configured projects: anna, bob, company"])
    }

    func testLaunchFocusesAppOfInactiveProject() async {
        setUpProjectsConfig()
        activeProjectName = "anna"
        runningAppsForTests = [annaChrome, bobChrome]
        let bobWindow = TestProjectWindow.new(id: 2, app: bobChrome, parent: focus.workspace.rootTilingContainer)
        let result = await run("project-launch --project bob --app chrome")
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(activeProjectName, "bob")
        assertEquals(focus.windowOrNil, bobWindow)
        assertEquals(projectSideEffectsForTests, [])
    }

    func testLaunchAllMissingAutostartApps() async {
        setUpProjectsConfig()
        activeProjectName = "company"
        runningAppsForTests = [annaChrome]
        // kitty is autostart = false. firefox has a launch command
        var result = await run("project-launch")
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(projectSideEffectsForTests, [
            launch("open -na \"Google Chrome\" --args --user-data-dir=\"$HOME/.chrome/company\"", "company"),
            launch("open -a Firefox", "company"),
            launch("cursor --user-data-dir ~/.cursor-projects/company '\(homeDirPath)/src/company-infra'", "company"),
        ])

        // Running instances are skipped
        projectSideEffectsForTests = []
        result = await run("project-launch --project anna")
        assertEquals(projectSideEffectsForTests, [
            launch("kitty --single-instance --instance-group anna herdr --session anna", "anna"),
            annaCursorLaunch,
        ])

        // No active project and no --app
        activeProjectName = nil
        result = await run("project-launch")
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, ["No project is active. Please specify --project or --app"])
    }

    func testLaunchMissingOnSwitch() async {
        setUpProjectsConfig()
        runningAppsForTests = [annaChrome, annaKitty]
        var result = await run("project anna --launch-missing")
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(activeProjectName, "anna")
        assertEquals(projectSideEffectsForTests, [annaCursorLaunch])

        projectSideEffectsForTests = []
        result = await run("project bob")
        assertEquals(activeProjectName, "bob")
        assertEquals(projectSideEffectsForTests, []) // No --launch-missing
    }

    func testGlobalFallbackForAppsTheActiveProjectDoesntReference() async {
        setUpProjectsConfig(projectsTestConfig + "\n[[projects]]\nname = 'p'\napps = ['cursor']\n")
        activeProjectName = "p"
        runningAppsForTests = [annaChrome, personalChrome, slack]
        let root = focus.workspace.rootTilingContainer
        TestProjectWindow.new(id: 1, app: annaChrome, parent: root)
        let personalWindow = TestProjectWindow.new(id: 2, app: personalChrome, parent: root)
        let slackWindow = TestProjectWindow.new(id: 3, app: slack, parent: root)
        assertTrue(slackWindow.focusWindow())

        // 'p' doesn't reference chrome -> the global instance, not anna's
        var result = await run("project-launch --app chrome")
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(focus.windowOrNil, personalWindow)
        assertEquals(activeProjectName, "p")

        // An explicit --project still fails
        result = await run("project-launch --project p --app chrome")
        assertEquals(result.stderr, ["Project 'p' doesn't reference app 'chrome'"])
    }

    func testGlobalFallback() async {
        setUpProjectsConfig()
        runningAppsForTests = [annaChrome, personalChrome, slack]
        let root = focus.workspace.rootTilingContainer
        TestProjectWindow.new(id: 1, app: annaChrome, parent: root)
        let personalWindow = TestProjectWindow.new(id: 2, app: personalChrome, parent: root)
        let slackWindow = TestProjectWindow.new(id: 3, app: slack, parent: root)
        assertTrue(slackWindow.focusWindow())

        // The global instance is running -> focus it. Never the project instance
        assertEquals(getGlobalAppInstancePids(bundleId: "com.google.Chrome", runningAppsForTests), [personalChrome.pid])
        var result = await run("project-launch --app chrome")
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(focus.windowOrNil, personalWindow)
        assertEquals(projectSideEffectsForTests, [])

        // The global instance isn't running -> global-launch
        runningAppsForTests = [annaChrome, slack]
        result = await run("project-launch --app chrome")
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(projectSideEffectsForTests, [launch("open -na \"Google Chrome\"", "")])

        projectSideEffectsForTests = []
        result = await run("project-launch --app kitty")
        assertEquals(result.stderr, ["App 'kitty' has no 'global-launch' command"])
        result = await run("project-launch --app cursor")
        assertEquals(result.stderr, ["App 'cursor' has no 'bundle-id'. It's required to find the global instance"])
        result = await run("project-launch --app safari")
        assertEquals(result.stderr, ["Unknown project app 'safari'. It must be declared in [project-apps.safari]"])
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(projectSideEffectsForTests, [])
    }

    func testProjectQuit() async {
        setUpProjectsConfig()
        runningAppsForTests = [annaChrome, annaKitty, bobChrome, personalChrome, slack]
        var result = await run("project-quit")
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, ["No project is active. Please specify <project-name>"])

        activeProjectName = "anna"
        result = await run("project-quit")
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(projectSideEffectsForTests, [.terminate(pid: annaChrome.pid), .terminate(pid: annaKitty.pid)])
        assertEquals(activeProjectName, "anna") // The active project stays active

        projectSideEffectsForTests = []
        result = await run("project-quit bob")
        assertEquals(projectSideEffectsForTests, [.terminate(pid: bobChrome.pid)])
        assertEquals(activeProjectName, "anna")

        result = await run("project-quit dave")
        assertEquals(result.stderr, ["Unknown project 'dave'. Configured projects: anna, bob, company"])
    }

    func testMoveAppToProject() async {
        setUpProjectsConfig()
        activeProjectName = "anna"
        runningAppsForTests = [annaChrome, bobChrome, slack]
        let bobWindow = TestProjectWindow.new(id: 2, app: bobChrome, parent: focus.workspace.rootTilingContainer)

        // --pid
        var result = await run("move-app-to-project bob --pid \(slack.pid)")
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(getProjectName(of: slack), "bob")
        // The focused window's process. The override beats the config rules
        assertTrue(bobWindow.focusWindow())
        result = await run("move-app-to-project anna")
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(getProjectName(of: bobChrome), "anna")
        result = await run("move-app-to-project --none --pid \(annaChrome.pid)")
        assertEquals(getProjectOwnership(annaChrome), .global)

        // The overrides survive reload-config
        resetProjectOwnershipCache()
        assertEquals(getProjectName(of: slack), "bob")
        assertEquals(getProjectName(of: bobChrome), "anna")
        assertNil(getProjectName(of: annaChrome))

        // Visibility is re-applied using the new ownership: bob is inactive, so the process is hidden
        let states = [slack, bobChrome, annaChrome].map { ProjectAppState(pid: $0.pid, project: getProjectName(of: $0), isHidden: false) }
        assertEquals(getProjectVisibilityPlan(activeProject: "anna", apps: states, projectHiddenPids: []), ProjectVisibilityPlan(toUnhide: [], toHide: [slack.pid]))

        // The overrides live until the process exits
        runningAppsForTests = [annaChrome, bobChrome]
        await reapplyProjectVisibility()
        assertEquals(projectOwnershipOverrides.keys.sorted(), [annaChrome.pid, bobChrome.pid])
        assertNil(getProjectName(of: slack))

        result = await run("move-app-to-project anna --pid 999")
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, ["No running app with pid 999"])
        result = await run("move-app-to-project dave --pid \(slack.pid)")
        assertEquals(result.stderr, ["Unknown project 'dave'. Configured projects: anna, bob, company"])
    }

    func testMoveAppToProjectWithoutFocusedWindow() async {
        setUpProjectsConfig()
        let result = await run("move-app-to-project anna")
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, [noWindowIsFocused])
    }

    func testProjectChangedEnvVars() {
        assertEquals(getProjectChangedEnvVars(prev: nil, new: "anna"), [AEROSPACE_PROJECT: "anna", AEROSPACE_PREV_PROJECT: ""])
        assertEquals(getProjectChangedEnvVars(prev: "anna", new: nil), [AEROSPACE_PROJECT: "", AEROSPACE_PREV_PROJECT: "anna"])
        let env = CmdEnv.defaultEnv.withEnvVars(getProjectChangedEnvVars(prev: "anna", new: "bob")).withWindowId(5)
        assertEquals(env.asMap, [AEROSPACE_PROJECT: "bob", AEROSPACE_PREV_PROJECT: "anna", AEROSPACE_WINDOW_ID: "5"])
        assertEquals(CmdEnv.defaultEnv.asMap, [:])
    }

    func testTestCommandDashDash() {
        let args = parseArgs("test %{app-args} ~= -- --user-data-dir=foo", as: TestCmdArgs.self)
        assertEquals(args?.rhs.val, "--user-data-dir=foo")
        assertEquals(args?.infixOperator.val, .matchesRegex)
        assertEquals(parseArgs("test-not %{app-name} = -- -x", as: TestNotCmdArgs.self)?.testArgs.rhs.val, "-x")
        // Backwards compatibility: `--` as the last argument is <rhs>
        assertEquals(parseArgs("test %{app-name} = --", as: TestCmdArgs.self)?.rhs.val, "--")
        assertEquals(parseArgs("test %{app-name} = -- --", as: TestCmdArgs.self)?.rhs.val, "--")
        assertEquals(parseArgs("test %{app-name} = foo", as: TestCmdArgs.self)?.rhs.val, "foo")
        assertEquals(parseCommand("test %{app-args} ~= --user-data-dir").errorOrNil, "ERROR: Unknown flag '--user-data-dir'\nERROR: Argument '<rhs>' is mandatory")
        assertEquals(parseCommand("test %{app-name} = -- a b").errorOrNil, "ERROR: Unknown argument 'b'")

        assertTrue(parseProjectAppMatcher("test %{app-args} ~= -- '--user-data-dir=.*/anna( |$)'").getOrDie().matchesProjectApp(annaChrome))
        assertFalse(parseProjectAppMatcher("test %{app-args} ~= -- '--user-data-dir=.*/anna( |$)'").getOrDie().matchesProjectApp(bobChrome))
    }

    func testListWindowsProjectAlone() async {
        setUpProjectsConfig()
        TestProjectWindow.new(id: 1, app: annaChrome, parent: focus.workspace.rootTilingContainer)
        TestProjectWindow.new(id: 2, app: bobChrome, parent: focus.workspace.rootTilingContainer)
        TestProjectWindow.new(id: 3, app: annaKitty, parent: Workspace.get(byName: "other").rootTilingContainer)
        assertEquals(parseArgs("list-windows --project anna", as: ListWindowsCmdArgs.self)?.filteringOptions.monitors, [.all])
        func windowIds(_ cmd: String) async -> [String] {
            await run(cmd + " --format %{window-id}").stdout.sorted()
        }
        assertEquals(await windowIds("list-windows --project anna"), ["1", "3"])
        assertEquals(await windowIds("list-windows --project --none"), [])
        // Combinations keep working
        assertEquals(await windowIds("list-windows --project anna --workspace focused"), ["1"])
        assertEquals(await windowIds("list-windows --project anna --monitor all"), ["1", "3"])
        assertEquals(await windowIds("list-windows --project anna --workspace other"), ["3"])
        assertEquals(parseCommand("list-windows --project anna --focused").errorOrNil, "--focused conflicts with other \"filtering\" flags")
    }

    func testConfigValidation() {
        let result = parseConfig(
            """
            [project-apps.a]
            if = 'true'
            bundle-id = 'com example'
            [project-apps.b]
            if = 'true'
            global-launch = 'open -na B'
            [project-apps.c]
            if = 'test %{app-args} ~= {project}'
            global-launch = 'open -na C --args {project}'
            bundle-id = 'com.example.c'
            launch = 'c {project}'

            [[projects]]
            name = 'anna'
            apps = [{ app = 'c', open = ['~/x'] }]
            """,
        )
        assertEquals(result.strErrors.sorted(), [
            "[ERROR] project-apps.a.bundle-id: Invalid bundle ID 'com example'. It must be non-empty and must not contain whitespaces",
            "[ERROR] project-apps.b.global-launch: 'global-launch' requires 'bundle-id'. It's used to find the running global instance",
            "[ERROR] project-apps.c.global-launch: 'global-launch' must not contain {project} placeholder",
            "[ERROR] projects[0].apps[0].open: 'open' requires {open} placeholder in 'launch' of [project-apps.c]",
        ])
        assertEquals(parseConfig(projectsTestConfig).config.projectApps["chrome"]?.bundleId, "com.google.Chrome")
    }
}
