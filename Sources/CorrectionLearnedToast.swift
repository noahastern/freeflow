import AppKit
import SwiftUI

/// Brief "Learned: Kubernetes" confirmation with Undo. A non-activating panel, so showing
/// it or clicking Undo never takes focus from the app the user is typing in.
final class CorrectionLearnedToast {
    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?

    static let displayDuration: TimeInterval = 6

    func show(meant: String, onUndo: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        dismiss()

        let width: CGFloat = 300
        let height: CGFloat = 36
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        let view = CorrectionLearnedToastView(meant: meant) { [weak self] in
            onUndo()
            self?.dismiss()
        }
        .frame(width: width, height: height)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        panel.contentView = hosting

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - width / 2, y: visible.maxY - height - 12))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        let workItem = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.displayDuration, execute: workItem)
    }

    func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        guard let panel else { return }
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
        self.panel = nil
    }
}

private struct CorrectionLearnedToastView: View {
    let meant: String
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.green)
            Text("Learned: \(meant)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button("Undo", action: onUndo)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(Color.black.opacity(0.88)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
    }
}
