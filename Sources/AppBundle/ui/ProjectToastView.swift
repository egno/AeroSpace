import AppKit
import Common
import SwiftUI

/// Short HUD with the project name, shown after a project switch
public final class ProjectToastPanel: NSPanelHud {
    @MainActor public static var shared: ProjectToastPanel = ProjectToastPanel()
    private var timer: Timer?

    override private init() {
        super.init()
    }

    func show(_ text: String, on monitor: MonitorInfo) {
        timer?.invalidate()
        self.contentView?.subviews.removeAll()
        let hostingView = NSHostingView(rootView: ProjectToastView(text: text))
        let size = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: size)
        self.contentView?.addSubview(hostingView)
        // NSScreen frames are in AppKit coordinates (bottom-left origin), unlike MonitorInfo.rect
        let screenFrame = NSScreen.screens.getOrNil(atIndex: monitor.monitorAppKitNsScreenScreensId - 1)?.frame ?? .zero
        let origin = NSPoint(x: screenFrame.midX - size.width / 2, y: screenFrame.midY - size.height / 2)
        self.setFrame(NSRect(origin: origin, size: size), display: true)
        self.orderFrontRegardless()
        timer = .scheduledTimer(withTimeInterval: 0.7 /* seconds */, repeats: false) { [weak self] _ in
            Task.startUnstructured { @MainActor in
                self?.close()
            }
        }
    }
}

struct ProjectToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 36, weight: .semibold))
            .padding(.horizontal, 32)
            .padding(.vertical, 18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
