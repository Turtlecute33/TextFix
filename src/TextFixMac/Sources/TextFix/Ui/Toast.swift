// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// The failure notice: a small HUD panel that slides in under the menu bar, says what went wrong
/// in something the user can act on, and takes itself away.
///
/// Deliberately not a User Notification. An agent with no Dock icon would have to ask for
/// notification permission before it could say anything at all, and the first thing it would ever
/// have to say is "that did not work" - which is exactly the wrong moment to be interrupted by a
/// permission prompt. Drawing it means TextFix can be installed, granted Accessibility, and used,
/// without a second system dialog anywhere in the path.
final class Toast: NSObject {
    static let shared = Toast()

    private let width: CGFloat = 340
    private let dismissAfter: TimeInterval = 4.5

    private var panel: NSPanel?
    private var dismissTimer: Timer?

    private override init() { super.init() }

    func show(title: String, message: String, isError: Bool) {
        dismissTimer?.invalidate()
        panel?.orderOut(nil)
        panel = nil

        let content = buildContent(title: title, message: message, isError: isError)
        let size = NSSize(width: width, height: content.fittingSize.height)
        content.frame = NSRect(origin: .zero, size: size)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.contentView = content

        let screen = NSScreen.main ?? NSScreen.screens.first
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: (frame.midX - size.width / 2).rounded(),
                y: (frame.maxY - size.height - 12).rounded()))
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        self.panel = panel
        dismissTimer = Timer.scheduledTimer(withTimeInterval: dismissAfter, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    @objc func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    func shutdown() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func buildContent(title: String, message: String, isError: Bool) -> NSView {
        let effect = ClickThroughEffectView()
        effect.translatesAutoresizingMaskIntoConstraints = false
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.onClick = { [weak self] in self?.dismiss() }

        let symbol = isError ? "exclamationmark.triangle.fill" : "info.circle.fill"
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        icon.contentTintColor = isError ? .systemOrange : .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let titleLabel = Controls.label(title, font: .systemFont(ofSize: 13, weight: .semibold))
        let messageLabel = Controls.label(message, font: .systemFont(ofSize: 12))
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.preferredMaxLayoutWidth = width - 66

        let text = NSStackView(views: [titleLabel, messageLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(icon)
        effect.addSubview(text)

        // The effect view is laid out by constraints, so it is wrapped in a plain container that
        // keeps its autoresizing mask - which is what an NSWindow contentView has to have. Asking
        // the container for its fitting size is then what sizes the panel to the message.
        let container = NSView()
        container.addSubview(effect)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            icon.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),

            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            text.topAnchor.constraint(equalTo: effect.topAnchor, constant: 12),
            text.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -12),

            effect.widthAnchor.constraint(equalToConstant: width),
            effect.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            effect.topAnchor.constraint(equalTo: container.topAnchor),
            effect.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }
}

/// A visual effect view that dismisses the toast when it is clicked. The panel is
/// non-activating, so this never pulls the user out of whatever they were typing in.
private final class ClickThroughEffectView: NSVisualEffectView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) { onClick?() }
}
