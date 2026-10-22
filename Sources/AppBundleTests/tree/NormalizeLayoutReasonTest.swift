@testable import AppBundle
import Common
import XCTest

@MainActor
final class NormalizeLayoutReasonTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testHiddenAppWindowIsRestoredAtExactPosition() async throws {
        let workspace = Workspace.get(byName: name)
        var window2: TestWindow!
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0, adaptiveWeight: 1)
            window2 = TestWindow.new(id: 2, parent: $0, adaptiveWeight: 2)
            TestWindow.new(id: 3, parent: $0, adaptiveWeight: 3)
            assertTrue(TestWindow.new(id: 4, parent: $0, adaptiveWeight: 4).focusWindow()) // MRU is the last window
        }

        window2.isMacosAppHiddenForTest = true
        try await normalizeLayoutReason()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(3), .window(4)]))
        assertTrue(window2.parent === workspace.macOsNativeHiddenAppsWindowsContainer)

        window2.isMacosAppHiddenForTest = false
        try await normalizeLayoutReason()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2), .window(3), .window(4)]))
        assertEquals(workspace.rootTilingContainer.children.map { $0.getWeight(.h) }, [1, 2, 3, 4])
        assertEquals(window2.layoutReason, .standard)
        assertNil(window2.prevTilingBinding)
    }

    func testSeveralHiddenWindowsKeepRelativeOrder() async throws {
        let workspace = Workspace.get(byName: name)
        var hidden: [TestWindow] = []
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0, adaptiveWeight: 1)
            hidden.append(TestWindow.new(id: 2, parent: $0, adaptiveWeight: 2))
            TestWindow.new(id: 3, parent: $0, adaptiveWeight: 3)
            hidden.append(TestWindow.new(id: 4, parent: $0, adaptiveWeight: 4))
            hidden.append(TestWindow.new(id: 5, parent: $0, adaptiveWeight: 5))
        }

        for window in hidden { window.isMacosAppHiddenForTest = true }
        try await normalizeLayoutReason()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(3)]))

        for window in hidden { window.isMacosAppHiddenForTest = false }
        try await normalizeLayoutReason()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2), .window(3), .window(4), .window(5)]))
        assertEquals(workspace.rootTilingContainer.children.map { $0.getWeight(.h) }, [1, 2, 3, 4, 5])
    }

    func testWindowsHiddenInSeparatePassesAreRestoredTogether() async throws {
        let workspace = Workspace.get(byName: name)
        var window2: TestWindow!
        var window3: TestWindow!
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            window2 = TestWindow.new(id: 2, parent: $0)
            window3 = TestWindow.new(id: 3, parent: $0)
            TestWindow.new(id: 4, parent: $0)
        }

        window2.isMacosAppHiddenForTest = true
        try await normalizeLayoutReason()
        window3.isMacosAppHiddenForTest = true
        try await normalizeLayoutReason()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(4)]))

        window2.isMacosAppHiddenForTest = false
        window3.isMacosAppHiddenForTest = false
        try await normalizeLayoutReason()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2), .window(3), .window(4)]))
    }

    func testHiddenWindowInNestedContainer() async throws {
        let workspace = Workspace.get(byName: name)
        var window3: TestWindow!
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 2, parent: $0)
                window3 = TestWindow.new(id: 3, parent: $0, adaptiveWeight: 7)
                TestWindow.new(id: 4, parent: $0)
            }
            assertTrue(TestWindow.new(id: 5, parent: $0).focusWindow())
        }

        window3.isMacosAppHiddenForTest = true
        try await normalizeLayoutReason()
        window3.isMacosAppHiddenForTest = false
        try await normalizeLayoutReason()
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .v_tiles([.window(2), .window(3), .window(4)]), .window(5)]),
        )
        assertEquals(window3.getWeight(.v), 7)
    }

    func testFallbackIfParentIsRemoved() async throws {
        config.enableNormalizationFlattenContainers = true
        let workspace = Workspace.get(byName: name)
        var window3: TestWindow!
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 2, parent: $0)
                window3 = TestWindow.new(id: 3, parent: $0)
            }
            assertTrue(TestWindow.new(id: 4, parent: $0).focusWindow())
        }

        window3.isMacosAppHiddenForTest = true
        try await normalizeLayoutReason()
        workspace.normalizeContainers() // The v_tiles container is flattened away
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2), .window(4)]))

        window3.isMacosAppHiddenForTest = false
        try await normalizeLayoutReason()
        // Fallback: next to the MRU window
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2), .window(4), .window(3)]))
        assertNil(window3.prevTilingBinding)
    }

    func testFallbackIfWindowIsMovedToAnotherWorkspaceWhileHidden() async throws {
        let workspaceA = Workspace.get(byName: "a")
        let workspaceB = Workspace.get(byName: "b")
        var window2: TestWindow!
        workspaceA.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            window2 = TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
        }
        workspaceB.rootTilingContainer.apply {
            TestWindow.new(id: 4, parent: $0)
            TestWindow.new(id: 5, parent: $0)
            TestWindow.new(id: 6, parent: $0)
        }

        window2.isMacosAppHiddenForTest = true
        try await normalizeLayoutReason()
        window2.bind(to: workspaceB.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)

        window2.isMacosAppHiddenForTest = false
        try await normalizeLayoutReason()
        assertEquals(workspaceA.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(3)]))
        // Fallback: the window is laid out as a new window of workspace b
        assertTrue(window2.parent === workspaceB.rootTilingContainer)
    }

    func testHiddenFloatingWindowStaysFloating() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.floatingWindowsContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)

        window.isMacosAppHiddenForTest = true
        try await normalizeLayoutReason()
        assertNil(window.prevTilingBinding)
        window.isMacosAppHiddenForTest = false
        try await normalizeLayoutReason()
        assertTrue(window.parent === workspace.floatingWindowsContainer)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(2)]))
    }
}
