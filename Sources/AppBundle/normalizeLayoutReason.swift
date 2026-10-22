import AppKit

@MainActor
func normalizeLayoutReason() async throws {
    for workspace in Workspace.all {
        let windows: [Window] = workspace.allLeafWindowsRecursive
        try await _normalizeLayoutReason(workspace: workspace, windows: windows)
    }
    try await _normalizeLayoutReason(workspace: focus.workspace, windows: macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self))
    try await validateStillPopups()
}

@MainActor
private func validateStillPopups() async throws {
    for node in macosPopupWindowsContainer.children {
        let popup = (node as! MacWindow)
        let windowLevel = getWindowLevel(for: popup.windowId)
        if try await popup.isWindowHeuristic(windowLevel, .cancellable) {
            try await popup.relayoutWindow(on: focus.workspace, .cancellable)
            await runOnWindowDetected(ifConventional: popup)
        }
    }
}

@MainActor
private func _normalizeLayoutReason(workspace: Workspace, windows: [Window]) async throws {
    // Reversed: siblings leave their tiling parent from the last to the first, so remembered indices don't shift.
    // And windows of macOS native containers return in LIFO order, which restores their remembered indices exactly
    for window in windows.reversed() {
        let isMacosFullscreen = try await window.isMacosFullscreen(.cancellable)
        let isMacosMinimized = try await (!isMacosFullscreen).andAsync { @MainActor @Sendable in try await window.isMacosMinimized(.cancellable) }
        let isMacosWindowOfHiddenApp = !isMacosFullscreen && !isMacosMinimized &&
            !config.automaticallyUnhideMacosHiddenApps && window.isMacosAppHidden()
        switch window.layoutReason {
            case .standard:
                switch true {
                    case isMacosFullscreen:
                        window.enterMacOsNativeUnconventionalState(workspace.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER)
                    case isMacosMinimized:
                        window.enterMacOsNativeUnconventionalState(macosMinimizedWindowsContainer, adaptiveWeight: 1)
                    case isMacosWindowOfHiddenApp:
                        window.enterMacOsNativeUnconventionalState(workspace.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER)
                    default: break
                }
            case .macos(let prevParentKind):
                if !isMacosFullscreen && !isMacosMinimized && !isMacosWindowOfHiddenApp {
                    try await exitMacOsNativeUnconventionalState(window: window, prevParentKind: prevParentKind, workspace: workspace, .cancellable)
                }
        }
    }
}

extension Window {
    @MainActor
    fileprivate func enterMacOsNativeUnconventionalState(_ container: NonLeafTreeNodeObject, adaptiveWeight: CGFloat) {
        guard let parent else { return }
        layoutReason = .macos(prevParentKind: parent.kind)
        prevTilingBinding = PrevTilingBinding(bind(to: container, adaptiveWeight: adaptiveWeight, index: INDEX_BIND_LAST))
    }
}

@MainActor
func exitMacOsNativeUnconventionalState(
    window: Window,
    prevParentKind: NonLeafTreeNodeKind,
    workspace: Workspace,
    _ cm: CancellationMode,
) async throws {
    window.layoutReason = .standard
    let prevTilingBinding = window.prevTilingBinding
    window.prevTilingBinding = nil
    switch prevParentKind {
        case .floatingWindowsContainer:
            window.bindAsFloatingWindow(to: workspace)
        case .workspace:
            break // Not possible
        case .tilingContainer:
            if let prevTilingBinding, let parent = prevTilingBinding.parent, parent.nodeWorkspace === workspace {
                window.bind(to: parent, adaptiveWeight: prevTilingBinding.adaptiveWeight, index: min(prevTilingBinding.index, parent.children.count))
            } else {
                try await window.relayoutWindow(on: workspace, cm, forceTile: true)
            }
        case .macosPopupWindowsContainer: // Since the window was minimized/fullscreened it was mistakenly detected as popup. Relayout the window
            try await window.relayoutWindow(on: workspace, cm)
        case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer: // wtf case, should never be possible. But If encounter it, let's just re-layout window
            try await window.relayoutWindow(on: workspace, cm)
    }
}
