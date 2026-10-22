import AppKit

@MainActor
func normalizeLayoutReason() async throws {
    try await refreshWindowIfOwnership(.cancellable)
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
            (!config.automaticallyUnhideMacosHiddenApps || projectHiddenPids.contains(window.app.pid)) && window.isMacosAppHidden()
        // Per-window project ownership: windows of inactive projects leave the layout the same way as windows of hidden apps
        let isProjectHiddenWindow = !isMacosFullscreen && !isMacosMinimized && isWindowHiddenByProject(window)
        rememberWindowHiddenByProject(window, isProjectHiddenWindow)
        switch window.layoutReason {
            case .standard:
                switch true {
                    case isMacosFullscreen:
                        window.enterMacOsNativeUnconventionalState(workspace.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER)
                    case isMacosMinimized:
                        window.enterMacOsNativeUnconventionalState(macosMinimizedWindowsContainer, adaptiveWeight: 1)
                    case isMacosWindowOfHiddenApp || isProjectHiddenWindow:
                        window.enterMacOsNativeUnconventionalState(workspace.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER)
                    default: break
                }
            case .macos(let prevParentKind):
                if !isMacosFullscreen && !isMacosMinimized && !isMacosWindowOfHiddenApp && !isProjectHiddenWindow {
                    try await exitMacOsNativeUnconventionalState(window: window, prevParentKind: prevParentKind, workspace: workspace, .cancellable)
                } else if isProjectHiddenWindow && !(window.parent is MacosHiddenAppsWindowsContainer) {
                    // E.g. a window of an inactive project got unminimized. Keep the remembered place
                    window.bind(to: workspace.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                }
        }
    }
}

extension Window {
    @MainActor
    fileprivate func enterMacOsNativeUnconventionalState(_ container: NonLeafTreeNodeObject, adaptiveWeight: CGFloat) {
        guard let parent else { return }
        let order = (parent as? TilingContainer).map { parent in
            let order = getTilingChildrenOrder(parent)
            order.update(parent) // Remember the place of the window among the siblings
            return order
        }
        layoutReason = .macos(prevParentKind: parent.kind)
        prevTilingBinding = PrevTilingBinding(bind(to: container, adaptiveWeight: adaptiveWeight, index: INDEX_BIND_LAST), order: order)
    }
}

/// All windows that left the same tiling container share the order
@MainActor
private func getTilingChildrenOrder(_ parent: TilingContainer) -> TilingChildrenOrder {
    let leftWindows = Workspace.all.flatMap(\.allLeafWindowsRecursive) + macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self)
    return leftWindows.lazy.compactMap { $0.prevTilingBinding?.parent === parent ? $0.prevTilingBinding?.order : nil }.first
        ?? TilingChildrenOrder()
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
                let index = prevTilingBinding.order?.getRestoreIndex(of: window, in: parent) ?? prevTilingBinding.index
                window.bind(to: parent, adaptiveWeight: prevTilingBinding.adaptiveWeight, index: min(index, parent.children.count))
            } else {
                try await window.relayoutWindow(on: workspace, cm, forceTile: true)
            }
        case .macosPopupWindowsContainer: // Since the window was minimized/fullscreened it was mistakenly detected as popup. Relayout the window
            try await window.relayoutWindow(on: workspace, cm)
        case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer: // wtf case, should never be possible. But If encounter it, let's just re-layout window
            try await window.relayoutWindow(on: workspace, cm)
    }
}
