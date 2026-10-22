@testable import AppBundle
import Common
import XCTest

let projectsTestConfig = """
    config-version = 2
    on-inactive-project-activation = 'rehide'
    on-project-changed = 'exec-and-forget echo project'

    [project-apps.chrome]
    if = 'test %{app-bundle-id} = com.google.Chrome && test %{app-args} ~= -- "--user-data-dir=.*/\\.chrome/{project}( |$)"'
    launch = 'open -na "Google Chrome" --args --user-data-dir="$HOME/.chrome/{project}"'
    global-launch = 'open -na "Google Chrome"'
    bundle-id = 'com.google.Chrome'

    [project-apps.kitty]
    if = 'test %{app-bundle-id} = net.kovidgoyal.kitty && test %{app-args} ~= " --instance-group[= ]{project}( |$)"'
    launch = 'kitty --single-instance --instance-group {project} herdr --session {project}'
    bundle-id = 'net.kovidgoyal.kitty'

    [project-apps.cursor]
    if = 'test %{app-bundle-id} = com.todesktop.230313mzl4w4u92 && test %{app-args} ~= " --user-data-dir[= ].*/\\.cursor-projects/{project}( |$)"'
    launch = 'cursor --user-data-dir ~/.cursor-projects/{project} {open}'

    [project-apps.firefox]
    if = 'test %{app-bundle-id} = org.mozilla.firefox'
    launch = 'open -a Firefox'

    [[projects]]
    name = 'anna'
    apps = ['chrome', 'kitty', { app = 'cursor', open = ['~/src/anna-api', '~/src/anna-web'] }]

    [[projects]]
    name = 'bob'
    apps = ['chrome', 'kitty', { app = 'cursor', open = ['~/src/bob-app'] }]

    [[projects]]
    name = 'company'
    apps = ['chrome', 'firefox', { app = 'kitty', autostart = false }, { app = 'cursor', open = ['~/src/company-infra'] }]
    link-browser = 'firefox'
    """

@MainActor
final class ProjectConfigTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParseProjects() {
        let result = parseConfig(projectsTestConfig)
        assertEquals(result.strErrors, [])
        let config = result.config
        assertEquals(config.projects.map(\.name), ["anna", "bob", "company"])
        assertEquals(config.onInactiveProjectActivation, .rehide)
        assertTrue(config.onProjectChanged.flatten().singleOrNil() is ExecAndForgetCommand)
        assertEquals(config.projectApps.keys.sorted(), ["chrome", "cursor", "firefox", "kitty"])
        assertEquals(config.projectApps["chrome"]?.globalLaunch, "open -na \"Google Chrome\"")
        assertTrue(config.projectApps["chrome"]?.isShared == true)
        assertTrue(config.projectApps["firefox"]?.isShared == false)

        let anna = config.projects[0]
        assertEquals(anna.apps.map(\.appId), ["chrome", "kitty", "cursor"])
        assertEquals(anna.apps[2].open, ["~/src/anna-api", "~/src/anna-web"])
        assertEquals(anna.apps[2].launch, "cursor --user-data-dir ~/.cursor-projects/anna {open}")
        assertEquals(anna.apps[1].launch, "kitty --single-instance --instance-group anna herdr --session anna")
        assertEquals(anna.linkBrowser, "chrome") // Defaults to chrome if referenced

        let company = config.projects[2]
        assertEquals(company.apps.map(\.appId), ["chrome", "firefox", "kitty", "cursor"])
        assertEquals(company.apps.map(\.autostart), [true, true, false, true])
        assertEquals(company.apps.map(\.isShared), [true, false, true, true])
        assertEquals(company.linkBrowser, "firefox")
    }

    func testNoProjects() {
        let result = parseConfig("")
        assertEquals(result.errors, [])
        assertTrue(result.config.projects.isEmpty)
        assertTrue(result.config.projectApps.isEmpty)
        assertEquals(result.config.onInactiveProjectActivation, ._switch)
        config = result.config
        assertEquals(getProjectOwnership(TestProjectApp(pid: 10, bundleId: "com.google.Chrome", args: "")), .global)
    }

    func testProjectNameValidation() {
        let result = parseConfig(
            """
            [project-apps.firefox]
            if = 'test %{app-bundle-id} = org.mozilla.firefox'

            [[projects]]
            name = 'Anna'
            apps = ['firefox']

            [[projects]]
            name = 'a b'

            [[projects]]
            apps = []
            """,
        )
        assertEquals(result.strErrors, [
            "[ERROR] projects[0].name: Project name 'Anna' must match [a-z0-9_-]+ regex",
            "[ERROR] projects[1].name: Project name 'a b' must match [a-z0-9_-]+ regex",
            "[ERROR] projects[2]: 'name' is mandatory key",
        ])
    }

    func testUnknownAppAndDuplicates() {
        let result = parseConfig(
            """
            [project-apps.firefox]
            if = 'test %{app-bundle-id} = org.mozilla.firefox'

            [[projects]]
            name = 'anna'
            apps = ['chrome', 'firefox', { app = 'firefox' }, { autostart = false }, 1]
            link-browser = 'safari'

            [[projects]]
            name = 'anna'
            """,
        )
        assertEquals(result.strErrors, [
            "[ERROR] projects[0].apps[3]: 'app' is mandatory key",
            "[ERROR] projects[0].apps[4]: Expected types are 'string' or 'table'. But actual type is 'int'",
            "[ERROR] projects[0].apps[0]: Unknown project app 'chrome'. It must be declared in [project-apps.chrome]",
            "[ERROR] projects[0].apps[2]: App 'firefox' is referenced more than once in project 'anna'",
            "[ERROR] projects[0].link-browser: Unknown project app 'safari'",
            "[ERROR] projects[1].name: Duplicated project name 'anna'",
        ])
    }

    func testWholeAppReferencedBySeveralProjects() {
        let result = parseConfig(
            """
            [project-apps.firefox]
            if = 'test %{app-bundle-id} = org.mozilla.firefox'
            [project-apps.chrome]
            if = 'test %{app-args} ~= "{project}"'

            [[projects]]
            name = 'anna'
            apps = ['firefox', 'chrome']

            [[projects]]
            name = 'bob'
            apps = ['firefox', 'chrome']
            """,
        )
        assertEquals(result.strErrors, [
            "[ERROR] project-apps.firefox: Whole-app definition 'firefox' (its 'if' doesn't contain {project}) " +
                "is referenced by several projects: anna, bob. A whole-app definition can be referenced only by a single project",
        ])
    }

    func testProjectAppDefValidation() {
        let result = parseConfig(
            """
            on-inactive-project-activation = 'peek'

            [project-apps.a]
            launch = 'foo'
            [project-apps.b]
            if = 'workspace 1'
            [project-apps.c]
            if = 'test %{window-title} = foo'
            [project-apps.d]
            if = 'test %{app-project} = foo'
            [project-apps.e]
            if = 'true | true'
            [project-apps.f]
            if = 'test-not %{app-pid} = 1 || false'
            unknown = 1

            [[projects]]
            name = 'anna'
            apps = ['b', 'c', 'd', 'e', 'f']
            """,
        )
        assertEquals(result.strErrors, [
            "[ERROR] on-inactive-project-activation: Can't parse 'peek'.\nPossible values: (switch|rehide)",
            "[ERROR] project-apps.a: 'if' is mandatory key",
            "[ERROR] project-apps.f.unknown: Unknown key",
            "[ERROR] project-apps.b.if: Only 'test', 'test-not', 'true' and 'false' commands are allowed in project app matchers. Got: 'workspace'",
            "[ERROR] project-apps.c.if: Only %{app-*} interpolation variables are allowed in project app matchers. Got: %{window-title}",
            "[ERROR] project-apps.d.if: %{app-project} is not allowed in project app matchers",
            "[ERROR] project-apps.e.if: Pipes are not allowed in project app matchers",
        ])
    }

    func testInvalidSharedMatcherIsReportedOnce() {
        let result = parseConfig(
            """
            [project-apps.kitty]
            if = 'test %{app-args} ~= "--instance-group {project}"'

            [[projects]]
            name = 'anna'
            apps = [1, 'kitty', 'chrome']

            [[projects]]
            name = 'bob'
            apps = ['kitty']
            """,
        )
        assertEquals(result.strErrors, [
            "[ERROR] projects[0].apps[0]: Expected types are 'string' or 'table'. But actual type is 'int'",
            "[ERROR] project-apps.kitty.if: ERROR: Unknown flag '--instance-group anna'\nERROR: Argument '<rhs>' is mandatory",
            "[ERROR] projects[0].apps[2]: Unknown project app 'chrome'. It must be declared in [project-apps.chrome]",
        ])
    }

    func testParseProjectCmdArgs() {
        testParseSingleCommandSucc("project anna", ProjectCmdArgs(rawArgs: []).copy(\._target, .direct("anna")))
        assertEquals(parseCommand("project next --wrap-around").cmdOrNil?.flatten().singleOrNil().map { ($0 as! ProjectCommand).args.target }, .relative(.next))
        assertEquals(parseCommand("project --none").cmdOrNil?.flatten().singleOrNil().map { ($0 as! ProjectCommand).args.target }, ProjectTarget.noProject)
        assertEquals(parseCommand("project -- next").cmdOrNil?.flatten().singleOrNil().map { ($0 as! ProjectCommand).args.target }, .direct("next"))
        assertEquals(parseCommand("project").errorOrNil, "Either <project-name>, (next|prev) or --none must be specified")
        assertEquals(parseCommand("project --none anna").errorOrNil, "--none is incompatible with <project-name> and (next|prev)")
        assertEquals(parseCommand("project --wrap-around anna").errorOrNil, "--wrap-around requires using (next|prev) argument")
        assertEquals(parseCommand("project Anna").errorOrNil, "ERROR: Project name 'Anna' must match [a-z0-9_-]+ regex")
        assertNotNil(parseCommand("project-back-and-forth").cmdOrNil)
        assertNotNil(parseCommand("list-projects --active --json").cmdOrNil)
        assertNotNil(parseCommand("list-projects --format '%{project-name} %{project-running-apps}'").cmdOrNil)
        assertEquals(parseCommand("list-projects --count --json").errorOrNil, "ERROR: Conflicting options: --count, --json")
        assertEquals(parseCommand("list-projects --format %{app-pid}").cmdOrNil == nil, false) // Unknown variables are reported on run
    }

    func testParseProjectFilters() {
        func listWindowsFilter(_ cmd: String) -> ProjectFilter? {
            (parseCommand(cmd).cmdOrNil?.flatten().singleOrNil() as? ListWindowsCommand)?.args.filteringOptions.projectFilter
        }
        func listAppsArgs(_ cmd: String) -> ListAppsCmdArgs? {
            (parseCommand(cmd).cmdOrNil?.flatten().singleOrNil() as? ListAppsCommand)?.args
        }
        assertEquals(listWindowsFilter("list-windows --monitor all --project anna"), .name("anna"))
        assertEquals(listWindowsFilter("list-windows --monitor all --project --none"), ProjectFilter.global)
        assertEquals(listWindowsFilter("list-windows --project --active --monitor all"), .active)
        assertEquals(parseCommand("list-windows --monitor all --project").errorOrNil, "ERROR: '--project' must be followed by '(<project-name>|--none|--active)'")
        assertEquals(parseCommand("list-windows --all --project anna").errorOrNil, "--all conflicts with \"filtering\" flags. Please use '--monitor all' instead of '--all' alias")
        assertEquals(listAppsArgs("list-apps --project --none")?.projectFilter, ProjectFilter.global)
        assertEquals(listAppsArgs("list-apps --pid 42 --format %{app-project}")?.pidFilter, 42)
        assertEquals(parseCommand("list-apps --pid foo").errorOrNil, "ERROR: Failed to parse 'foo' CLI argument: Can't convert to Int32")
    }

    func testParseSubscribeProjectChanged() {
        assertEquals((parseCommand("subscribe project-changed").cmdOrNil == nil), true) // subscribe isn't a server command
        assertEquals(parseSubscribeCmdArgs(["project-changed"].slice).cmdOrNil?.events, [.projectChanged])
    }
}
