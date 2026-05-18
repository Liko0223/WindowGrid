import AppKit
import Carbon.HIToolbox

final class ShortcutCaptureView: NSView {
    private let promptLabel = NSTextField(labelWithString: "Press shortcut")
    private let shortcutLabel = NSTextField(labelWithString: "Click here, then press keys")

    private(set) var shortcut: KeyboardShortcut?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        promptLabel.frame = NSRect(x: 12, y: 54, width: bounds.width - 24, height: 20)
        promptLabel.autoresizingMask = [.width, .minYMargin]
        promptLabel.font = .systemFont(ofSize: 12, weight: .medium)
        addSubview(promptLabel)

        shortcutLabel.frame = NSRect(x: 12, y: 18, width: bounds.width - 24, height: 28)
        shortcutLabel.autoresizingMask = [.width, .minYMargin]
        shortcutLabel.alignment = .center
        shortcutLabel.font = .monospacedSystemFont(ofSize: 18, weight: .semibold)
        shortcutLabel.textColor = .secondaryLabelColor
        addSubview(shortcutLabel)
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode != UInt16(kVK_Escape),
              event.keyCode != UInt16(kVK_Return),
              event.keyCode != UInt16(kVK_ANSI_KeypadEnter)
        else {
            super.keyDown(with: event)
            return
        }

        let keyEquivalent = keyEquivalent(for: event)
        guard !keyEquivalent.isEmpty else {
            NSSound.beep()
            return
        }

        let carbonModifiers = KeyboardShortcut.carbonModifiers(from: event.modifierFlags)
        let shortcut = KeyboardShortcut(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: carbonModifiers,
            keyEquivalent: keyEquivalent
        )
        self.shortcut = shortcut
        shortcutLabel.stringValue = shortcut.displayName
        shortcutLabel.textColor = .labelColor
    }

    private func keyEquivalent(for event: NSEvent) -> String {
        let raw = event.charactersIgnoringModifiers ?? ""
        if let first = raw.lowercased().first, first.isLetter || first.isNumber {
            return String(first)
        }

        switch Int(event.keyCode) {
        case kVK_Space:
            return "space"
        case kVK_Tab:
            return "tab"
        case kVK_ForwardDelete, kVK_Delete:
            return "delete"
        default:
            return ""
        }
    }
}
