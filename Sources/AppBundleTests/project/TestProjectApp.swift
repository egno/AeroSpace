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

final class TestProjectWindow: Window {
    @MainActor
    @discardableResult
    static func new(id: UInt32, app: TestProjectApp, parent: NonLeafTreeNodeObject) -> TestProjectWindow {
        TestProjectWindow(id: id, app, lastFloatingSize: nil, parent: parent, adaptiveWeight: 1, index: INDEX_BIND_LAST)
    }

    @MainActor override func nativeFocus() {}
    override func closeAxWindow() { unbindFromParent() }
    override func getTitle(_ cm: CancellationMode) async throws -> String { "TestProjectWindow(\(windowId))" }
    @MainActor override func getAxRect(_ cm: CancellationMode) async throws -> Rect? { nil }
    @MainActor override func getAxSize(_ cm: CancellationMode) async throws -> CGSize? { nil }
}
