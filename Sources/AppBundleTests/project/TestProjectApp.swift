@testable import AppBundle
import AppKit
import Common

final class TestProjectApp: AbstractApp {
    let pid: Int32
    let rawAppBundleId: String?
    let name: String?
    let execPath: String? = nil
    let bundlePath: String? = nil
    let args: String?

    init(pid: Int32, bundleId: String, args: String) {
        self.pid = pid
        self.rawAppBundleId = bundleId
        self.name = bundleId
        self.args = args
    }

    @MainActor func getFocusedWindow(_ cm: CancellationMode) -> Window? { nil }
}

final class TestProjectWindow: Window, CustomStringConvertible {
    nonisolated var description: String { "TestProjectWindow(\(windowId))" }

    @MainActor var title: String? = nil

    @MainActor
    @discardableResult
    static func new(id: UInt32, app: TestProjectApp, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat = 1, title: String? = nil) -> TestProjectWindow {
        let window = TestProjectWindow(id: id, app, lastFloatingSize: nil, parent: parent, adaptiveWeight: adaptiveWeight, index: INDEX_BIND_LAST)
        window.title = title
        return window
    }

    @MainActor override func nativeFocus() {}
    override func closeAxWindow() { unbindFromParent() }
    @MainActor override func getTitle(_ cm: CancellationMode) async throws -> String { title ?? "TestProjectWindow(\(windowId))" }
    @MainActor override func getAxRect(_ cm: CancellationMode) async throws -> Rect? { nil }
    @MainActor override func getAxSize(_ cm: CancellationMode) async throws -> CGSize? { nil }
}
