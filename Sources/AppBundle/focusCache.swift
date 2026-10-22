@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?) {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return
    }
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        _ = nativeFocused?.focusWindow()
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
    }
    nativeFocused?.macAppUnsafe.lastNativeFocusedWindowId = nativeFocused?.windowId
}

@MainActor func isNativeFocusChanged(_ nativeFocused: Window) -> Bool { nativeFocused.windowId != lastKnownNativeFocusedWindowId }

/// The native focus is handled without taking it into AeroSpace focus (see handleInactiveProjectWindowActivation)
@MainActor func markNativeFocusAsSeen(_ nativeFocused: Window) {
    lastKnownNativeFocusedWindowId = nativeFocused.windowId
}
