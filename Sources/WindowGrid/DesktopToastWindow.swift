import AppKit
import Carbon.HIToolbox

protocol DesktopToastWindowDelegate: AnyObject {
    func desktopToastWindowDidMove(_ window: DesktopToastWindow)
    func desktopToastWindow(_ window: DesktopToastWindow, didCommitDesktopName name: String)
}

final class DesktopToastWindow: NSWindow {
    weak var toastDelegate: DesktopToastWindowDelegate?
    private let toastView = DesktopToastView(frame: NSRect(x: 0, y: 0, width: 120, height: 46))
    private var hideWorkItem: DispatchWorkItem?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 46),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        hasShadow = false
        isMovableByWindowBackground = true
        contentView = toastView
        alphaValue = 0
        toastView.onBeginEditing = { [weak self] in
            self?.cancelScheduledHide()
        }
        toastView.onCancelEditing = { [weak self] in
            self?.scheduleHide(after: 1.6)
        }
        toastView.onCommitName = { [weak self] name in
            guard let self else { return }
            cancelScheduledHide()
            toastDelegate?.desktopToastWindow(self, didCommitDesktopName: name)
        }
    }

    override var canBecomeKey: Bool {
        true
    }

    func persistMovedPosition() {
        toastDelegate?.desktopToastWindowDidMove(self)
    }

    func show(title: String, name: String?, near screen: NSScreen, savedPosition: NSPoint?) {
        cancelScheduledHide()
        toastView.set(title: title, name: name)
        let preferredSize = toastView.preferredSize(maxWidth: screen.visibleFrame.width - 48)

        let targetOrigin = clampedOrigin(savedPosition ?? defaultOrigin(on: screen), size: preferredSize, on: screen)
        toastView.frame = NSRect(origin: .zero, size: preferredSize)
        toastView.needsLayout = true
        toastView.layoutSubtreeIfNeeded()
        setFrame(NSRect(origin: targetOrigin, size: preferredSize), display: false)
        setFrameOrigin(targetOrigin)
        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }

        scheduleHide(after: 4.0)
    }

    func hide() {
        cancelScheduledHide()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }

    private func cancelScheduledHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    private func scheduleHide(after delay: TimeInterval) {
        cancelScheduledHide()
        let workItem = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        toastDelegate?.desktopToastWindowDidMove(self)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        toastDelegate?.desktopToastWindowDidMove(self)
    }

    private func defaultOrigin(on screen: NSScreen) -> NSPoint {
        let frame = screen.visibleFrame
        return NSPoint(
            x: frame.midX - self.frame.width / 2,
            y: frame.maxY - self.frame.height - 84
        )
    }

    private func clampedOrigin(_ origin: NSPoint, size: NSSize, on screen: NSScreen) -> NSPoint {
        let frame = screen.visibleFrame.insetBy(dx: 16, dy: 16)
        let maxX = max(frame.minX, frame.maxX - size.width)
        let maxY = max(frame.minY, frame.maxY - size.height)
        return NSPoint(
            x: min(max(origin.x, frame.minX), maxX),
            y: min(max(origin.y, frame.minY), maxY)
        )
    }
}

final class DesktopToastView: NSView, NSTextFieldDelegate {
    var onBeginEditing: (() -> Void)?
    var onCancelEditing: (() -> Void)?
    var onCommitName: ((String) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let editField = InlineDesktopNameField(frame: .zero)
    private let iconView = FourGridIconView(frame: NSRect(x: 14, y: 14, width: 16, height: 16))
    private var title = ""
    private var name: String?
    private var isEditingName = false
    private var shouldEditOnMouseUp = false
    private var mouseDownWindowOrigin = NSPoint.zero
    private var mouseDownScreenLocation = NSPoint.zero
    private var didDrag = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func set(title: String, name: String?) {
        self.title = title
        self.name = name
        if !isEditingName {
            titleLabel.isHidden = false
            editField.isHidden = true
            shouldEditOnMouseUp = false
        }
        titleLabel.stringValue = title
        needsLayout = true
        needsDisplay = true
    }

    func preferredSize(maxWidth: CGFloat) -> NSSize {
        let font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let textWidth = (title as NSString).size(withAttributes: [.font: font]).width
        let width = min(maxWidth, max(140, ceil(14 + 16 + 12 + textWidth + 18)))
        return NSSize(width: width, height: 46)
    }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: 14, y: headerMidY - 8, width: 16, height: 16)
        titleLabel.frame = NSRect(
            x: 42,
            y: headerMidY - 10,
            width: max(0, bounds.width - 56),
            height: 20
        )
        editField.frame = NSRect(
            x: 42,
            y: headerMidY - 12,
            width: max(0, bounds.width - 56),
            height: 24
        )
    }

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 16
        if #available(macOS 10.15, *) {
            layer?.cornerCurve = .continuous
        }
        layer?.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 0.86).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.borderWidth = 1

        shadow = NSShadow()
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow?.shadowBlurRadius = 14
        shadow?.shadowOffset = NSSize(width: 0, height: -4)

        iconView.autoresizingMask = [.maxXMargin, .minYMargin]
        addSubview(iconView)

        titleLabel.autoresizingMask = [.width, .minYMargin]
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.96)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        editField.isHidden = true
        editField.isBordered = false
        editField.isBezeled = false
        editField.drawsBackground = false
        editField.focusRingType = .none
        editField.font = .systemFont(ofSize: 14, weight: .semibold)
        editField.textColor = NSColor.white.withAlphaComponent(0.96)
        editField.placeholderString = "Desktop name"
        editField.delegate = self
        editField.target = self
        editField.action = #selector(editFieldAction)
        editField.onCommit = { [weak self] in
            self?.commitEditing()
        }
        editField.onCancel = { [weak self] in
            self?.cancelEditing()
        }
        addSubview(editField)
    }

    func beginEditing() {
        guard !isEditingName else { return }
        onBeginEditing?()
        isEditingName = true
        titleLabel.isHidden = true
        editField.isHidden = false
        editField.stringValue = name ?? ""
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(editField)
        DispatchQueue.main.async { [weak self] in
            self?.editField.currentEditor()?.selectAll(nil)
        }
        needsDisplay = true
    }

    @objc private func editFieldAction() {
        commitEditing()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard isEditingName else { return }
        let movement = obj.userInfo?["NSTextMovement"] as? Int
        if movement == NSCancelTextMovement {
            cancelEditing()
        } else {
            commitEditing()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseDownWindowOrigin = window?.frame.origin ?? .zero
        mouseDownScreenLocation = NSEvent.mouseLocation
        didDrag = false
        shouldEditOnMouseUp = editableRect.contains(point)
    }

    override func mouseDragged(with event: NSEvent) {
        let current = NSEvent.mouseLocation
        let dx = current.x - mouseDownScreenLocation.x
        let dy = current.y - mouseDownScreenLocation.y
        if hypot(dx, dy) > 3 {
            didDrag = true
            shouldEditOnMouseUp = false
            window?.setFrameOrigin(NSPoint(x: mouseDownWindowOrigin.x + dx, y: mouseDownWindowOrigin.y + dy))
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer {
            shouldEditOnMouseUp = false
        }

        if didDrag {
            (window as? DesktopToastWindow)?.persistMovedPosition()
            return
        }

        if shouldEditOnMouseUp && editableRect.contains(point) {
            beginEditing()
            return
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    @objc private func windowDidResignKey() {
        if isEditingName {
            commitEditing()
        }
    }

    private func commitEditing() {
        guard isEditingName else { return }
        let nextName = editField.stringValue
        isEditingName = false
        editField.isHidden = true
        titleLabel.isHidden = false
        window?.makeFirstResponder(nil)
        onCommitName?(nextName)
        needsDisplay = true
    }

    private func cancelEditing() {
        guard isEditingName else { return }
        isEditingName = false
        editField.isHidden = true
        titleLabel.isHidden = false
        window?.makeFirstResponder(nil)
        onCancelEditing?()
        needsDisplay = true
    }

    private var editableRect: NSRect {
        NSRect(x: 42, y: headerMidY - 14, width: max(0, bounds.width - 56), height: 28)
    }

    private var headerMidY: CGFloat {
        bounds.height - 23
    }

}

final class InlineDesktopNameField: NSTextField {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            onCommit?()
        case UInt16(kVK_Escape):
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }
}

final class FourGridIconView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let cell: CGFloat = 5.2
        let gap: CGFloat = 2.2
        let startX = (bounds.width - cell * 2 - gap) / 2
        let startY = (bounds.height - cell * 2 - gap) / 2

        for row in 0..<2 {
            for col in 0..<2 {
                let rect = NSRect(
                    x: startX + CGFloat(col) * (cell + gap),
                    y: startY + CGFloat(row) * (cell + gap),
                    width: cell,
                    height: cell
                )
                let path = NSBezierPath(roundedRect: rect, xRadius: 1.3, yRadius: 1.3)
                path.lineWidth = 1.2
                path.stroke()
            }
        }
    }
}
