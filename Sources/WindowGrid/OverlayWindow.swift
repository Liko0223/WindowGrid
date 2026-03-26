import AppKit

class OverlayWindow: NSWindow {
    private var gridView: GridOverlayView!
    private var layout: GridLayout
    private var highlightedZone: Int = -1

    init(screen: NSScreen, layout: GridLayout) {
        self.layout = layout
        let frame = screen.visibleFrame
        super.init(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        self.setFrame(frame, display: false)
        self.setFrameOrigin(frame.origin)

        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .init(Int(CGWindowLevelForKey(.floatingWindow)) + 1)
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]
        self.ignoresMouseEvents = true
        self.hasShadow = false
        self.alphaValue = 0

        gridView = GridOverlayView(frame: NSRect(origin: .zero, size: frame.size))
        gridView.layout = layout
        gridView.screenFrame = frame
        self.contentView = gridView
    }

    func updateLayout(_ newLayout: GridLayout) {
        self.layout = newLayout
        gridView.layout = newLayout
        gridView.needsDisplay = true
    }

    func highlightZone(at point: NSPoint) {
        guard let screen = self.screen else { return }
        let screenFrame = screen.visibleFrame
        if let zone = layout.zoneAt(point: point, in: screenFrame) {
            if zone.zone != highlightedZone {
                highlightedZone = zone.zone
                gridView.highlightedZone = zone.zone
                gridView.needsDisplay = true
            }
        }
    }

    func clearHighlight() {
        guard highlightedZone != -1 else { return }
        highlightedZone = -1
        gridView.highlightedZone = -1
        gridView.needsDisplay = true
    }

    func showWithAnimation() {
        self.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1.0
        }
    }

    func hideWithAnimation(completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.clearHighlight()
            completion?()
        })
    }
}

// MARK: - Grid Overlay View

class GridOverlayView: NSView {
    var layout: GridLayout = .sixGrid
    var screenFrame: NSRect = .zero
    var highlightedZone: Int = -1

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Dim background
        context.setFillColor(NSColor.black.withAlphaComponent(0.12).cgColor)
        context.fill(bounds)

        let zones = layout.zoneRects(in: screenFrame)

        for (index, zone) in zones.enumerated() {
            let viewRect = NSRect(
                x: zone.rect.origin.x - screenFrame.origin.x,
                y: zone.rect.origin.y - screenFrame.origin.y,
                width: zone.rect.width,
                height: zone.rect.height
            )

            let isHighlighted = index == highlightedZone

            // Zone fill
            if isHighlighted {
                context.setFillColor(NSColor.systemBlue.withAlphaComponent(0.25).cgColor)
            } else {
                context.setFillColor(NSColor.white.withAlphaComponent(0.06).cgColor)
            }

            let path = CGPath(roundedRect: viewRect, cornerWidth: 10, cornerHeight: 10, transform: nil)
            context.addPath(path)
            context.fillPath()

            // Zone border
            if isHighlighted {
                context.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.9).cgColor)
                context.setLineWidth(2.5)
            } else {
                context.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
                context.setLineWidth(1.0)
            }
            context.addPath(path)
            context.strokePath()

            // Zone number label
            let label = "\(index + 1)" as NSString
            let fontSize: CGFloat = min(viewRect.width, viewRect.height) * 0.12
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(16, min(fontSize, 36)), weight: .light),
                .foregroundColor: isHighlighted
                    ? NSColor.white.withAlphaComponent(0.85)
                    : NSColor.white.withAlphaComponent(0.2),
            ]
            let size = label.size(withAttributes: attrs)
            let labelPoint = NSPoint(
                x: viewRect.midX - size.width / 2,
                y: viewRect.midY - size.height / 2
            )
            label.draw(at: labelPoint, withAttributes: attrs)
        }
    }
}
