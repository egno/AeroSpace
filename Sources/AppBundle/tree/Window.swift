import AppKit
import Common

open class Window: TreeNode, Hashable {
    let windowId: UInt32
    let app: any AbstractApp
    var lastFloatingSize: CGSize?
    var isFullscreen: Bool = false
    var noOuterGapsInFullscreen: Bool = false
    var layoutReason: LayoutReason = .standard
    /// Where the window was in the tiling tree before it entered ``LayoutReason/macos(prevParentKind:)`` state
    var prevTilingBinding: PrevTilingBinding? = nil

    @MainActor
    init(id: UInt32, _ app: any AbstractApp, lastFloatingSize: CGSize?, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) {
        self.windowId = id
        self.app = app
        self.lastFloatingSize = lastFloatingSize
        super.init(parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor static func get(byId windowId: UInt32) -> Window? { // todo make non optional
        isUnitTest
            ? Workspace.all.flatMap { $0.allLeafWindowsRecursive }.first(where: { $0.windowId == windowId })
            : MacWindow.allWindowsMap[windowId]
    }

    @MainActor
    func closeAxWindow() { die("Not implemented") }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(windowId)
    }

    func getAxSize(_ cm: CancellationMode) async throws -> CGSize? { die("Not implemented") }
    func getTitle(_ cm: CancellationMode) async throws -> String { die("Not implemented") }
    func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { false }
    func isMacosMinimized(_ cm: CancellationMode) async throws -> Bool { false } // todo replace with enum MacOsWindowNativeState { normal, fullscreen, invisible }
    @MainActor func isMacosAppHidden() -> Bool { false }
    var isHiddenInCorner: Bool { die("Not implemented") }
    @MainActor func nativeFocus() { die("Not implemented") }
    func getAxRect(_ cm: CancellationMode) async throws -> Rect? { die("Not implemented") }
    func getCenter(_ cm: CancellationMode) async throws -> CGPoint? { try await getAxRect(cm)?.center }

    func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) { die("Not implemented") }
}

enum LayoutReason: Equatable {
    case standard
    /// Reason for the cur temp layout is macOS native fullscreen, minimize, or hide
    case macos(prevParentKind: NonLeafTreeNodeKind)
}

struct PrevTilingBinding {
    weak var parent: TilingContainer? // The container may be normalized away while the window is hidden
    let adaptiveWeight: CGFloat
    let index: Int
    /// Shared by all windows that left the same parent. Index is only a fallback
    let order: TilingChildrenOrder?

    init?(_ data: BindingData?, order: TilingChildrenOrder? = nil) {
        guard let data, let parent = data.parent as? TilingContainer else { return nil }
        self.parent = parent
        self.adaptiveWeight = data.adaptiveWeight
        self.index = data.index
        self.order = order
    }
}

/// The order of the tiling container's children including the windows that left it (hidden, minimized, fullscreen).
/// Remembered indices are not enough: when windows come back in a different order than they left
/// (e.g. some of them stay hidden), the indices point to wrong places
final class TilingChildrenOrder {
    private struct WeakNode {
        weak var node: TreeNode?
    }

    private var nodes: [WeakNode] = []

    /// Merges the current children of `parent` with the windows that left it. A left window stays right after its
    /// remembered predecessor. `leftWindow` counts as left even though its prevTilingBinding is already reset
    @MainActor
    @discardableResult
    func update(_ parent: TilingContainer, leftWindow: Window? = nil) -> [TreeNode] {
        var result = parent.children
        var predecessor: TreeNode? = nil
        for node in nodes.compactMap(\.node) {
            if !result.contains(where: { $0 === node }), let window = node as? Window,
               window === leftWindow || window.layoutReason != .standard && window.prevTilingBinding?.parent === parent
            {
                let index = predecessor.flatMap { p in result.firstIndex(where: { $0 === p }) }.map { $0 + 1 } ?? 0
                result.insert(window, at: index)
            }
            if result.contains(where: { $0 === node }) { predecessor = node }
        }
        nodes = result.map { WeakNode(node: $0) }
        return result
    }

    /// The index in `parent` to bring the left window back to
    @MainActor
    func getRestoreIndex(of window: Window, in parent: TilingContainer) -> Int? {
        let order = update(parent, leftWindow: window)
        guard let position = order.firstIndex(where: { $0 === window }) else { return nil }
        return order.prefix(position).count(where: { $0.parent === parent })
    }
}

extension Window {
    var isFloating: Bool { // todo drop. It will be a source of bugs when sticky is introduced
        switch windowParentCases {
            case .floatingWindowsContainer: true
            case .macosFullscreenWindowsContainer: false
            case .macosHiddenAppsWindowsContainer: false
            case .macosMinimizedWindowsContainer: false
            case .macosPopupWindowsContainer: false
            case .tilingContainer: false
            case .unbound: false
        }
    }

    @discardableResult
    @MainActor
    func bindAsFloatingWindow(to workspace: Workspace) -> BindingData? {
        bind(to: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }

    func asMacWindow() -> MacWindow { self as! MacWindow }
}
