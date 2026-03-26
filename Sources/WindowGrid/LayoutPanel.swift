import AppKit

protocol LayoutPanelDelegate: AnyObject {
    func layoutPanel(_ panel: LayoutPanel, didSelectLayout layout: GridLayout)
}

class LayoutPanel: NSWindow {
    weak var layoutDelegate: LayoutPanelDelegate?
    private var presetsView: PresetsGridView!
    private var customEditor: CustomGridEditor!
    private var segmentControl: NSSegmentedControl!
    private var currentLayout: GridLayout

    init(currentLayout: GridLayout) {
        self.currentLayout = currentLayout
        let width: CGFloat = 520
        let height: CGFloat = 460
        let frame = NSRect(x: 0, y: 0, width: width, height: height)

        super.init(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        self.title = "Grid Layout"
        self.center()
        self.isReleasedWhenClosed = false
        self.level = .floating

        setupUI()
    }

    private func setupUI() {
        let container = NSView(frame: self.contentView!.bounds)
        container.autoresizingMask = [.width, .height]
        self.contentView = container

        // Segment control: Presets | Custom
        segmentControl = NSSegmentedControl(labels: ["Presets", "Custom"], trackingMode: .selectOne, target: self, action: #selector(segmentChanged(_:)))
        segmentControl.selectedSegment = 0
        segmentControl.frame = NSRect(x: 20, y: container.bounds.height - 50, width: 200, height: 30)
        segmentControl.autoresizingMask = [.minYMargin]
        container.addSubview(segmentControl)

        let contentArea = NSRect(x: 0, y: 0, width: container.bounds.width, height: container.bounds.height - 60)

        // Presets view
        presetsView = PresetsGridView(frame: contentArea, currentLayout: currentLayout)
        presetsView.autoresizingMask = [.width, .height]
        presetsView.onSelect = { [weak self] layout in
            guard let self = self else { return }
            self.currentLayout = layout
            self.layoutDelegate?.layoutPanel(self, didSelectLayout: layout)
        }
        container.addSubview(presetsView)

        // Custom editor
        customEditor = CustomGridEditor(frame: contentArea)
        customEditor.autoresizingMask = [.width, .height]
        customEditor.isHidden = true
        customEditor.onApply = { [weak self] layout in
            guard let self = self else { return }
            self.currentLayout = layout
            self.layoutDelegate?.layoutPanel(self, didSelectLayout: layout)
        }
        customEditor.onSaved = { [weak self] in
            self?.presetsView.refreshPresets()
        }
        container.addSubview(customEditor)
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        presetsView.isHidden = sender.selectedSegment != 0
        customEditor.isHidden = sender.selectedSegment != 1
    }

    func showPanel() {
        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Presets Grid View

class PresetsGridView: NSView {
    var onSelect: ((GridLayout) -> Void)?
    private var currentLayout: GridLayout
    private var presetButtons: [NSButton] = []

    init(frame: NSRect, currentLayout: GridLayout) {
        self.currentLayout = currentLayout
        super.init(frame: frame)
        setupPresets()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refreshPresets() {
        presetButtons.forEach { $0.removeFromSuperview() }
        presetButtons.removeAll()
        setupPresets()
    }

    private func setupPresets() {
        let presets = ConfigStore.shared.allLayouts
        let cols = 3
        let btnW: CGFloat = 140
        let btnH: CGFloat = 100
        let padX: CGFloat = 20
        let padY: CGFloat = 15
        let startX: CGFloat = (bounds.width - CGFloat(cols) * (btnW + padX) + padX) / 2
        let startY: CGFloat = bounds.height - btnH - 20

        for (index, preset) in presets.enumerated() {
            let col = index % cols
            let row = index / cols
            let x = startX + CGFloat(col) * (btnW + padX)
            let y = startY - CGFloat(row) * (btnH + padY)

            let btn = PresetButton(frame: NSRect(x: x, y: y, width: btnW, height: btnH), layout: preset)
            btn.target = self
            btn.action = #selector(presetClicked(_:))
            btn.tag = index

            if preset.name == currentLayout.name {
                btn.setSelected(true)
            }

            addSubview(btn)
            presetButtons.append(btn)
        }
    }

    @objc private func presetClicked(_ sender: NSButton) {
        let allLayouts = ConfigStore.shared.allLayouts
        guard sender.tag < allLayouts.count else { return }
        let preset = allLayouts[sender.tag]
        currentLayout = preset

        // Update highlight
        for btn in presetButtons {
            (btn as? PresetButton)?.setSelected(false)
        }
        (sender as? PresetButton)?.setSelected(true)

        onSelect?(preset)
    }
}

// MARK: - Preset Button (thumbnail)

class PresetButton: NSButton {
    private let layout: GridLayout
    private var isSelected = false

    init(frame: NSRect, layout: GridLayout) {
        self.layout = layout
        super.init(frame: frame)
        self.isBordered = false
        self.title = ""
        self.wantsLayer = true
        self.layer?.cornerRadius = 8
        self.layer?.borderWidth = 1.5
        self.layer?.borderColor = NSColor.separatorColor.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        self.layer?.borderColor = selected
            ? NSColor.systemGreen.cgColor
            : NSColor.separatorColor.cgColor
        self.layer?.borderWidth = selected ? 2.5 : 1.5
        self.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Background
        let bgColor = isSelected
            ? NSColor.systemGreen.withAlphaComponent(0.08)
            : NSColor.controlBackgroundColor
        ctx.setFillColor(bgColor.cgColor)
        ctx.fill(bounds)

        // Draw mini grid preview
        let inset: CGFloat = 12
        let previewRect = bounds.insetBy(dx: inset, dy: inset + 14)
        let miniGap: CGFloat = 2
        let cellW = (previewRect.width - miniGap * CGFloat(layout.baseCols + 1)) / CGFloat(layout.baseCols)
        let cellH = (previewRect.height - miniGap * CGFloat(layout.baseRows + 1)) / CGFloat(layout.baseRows)

        for zone in layout.zones {
            let x = previewRect.origin.x + miniGap + CGFloat(zone.col) * (cellW + miniGap)
            let y = previewRect.origin.y + previewRect.height - miniGap - CGFloat(zone.row + zone.rowSpan) * (cellH + miniGap) + miniGap
            let w = cellW * CGFloat(zone.colSpan) + miniGap * CGFloat(zone.colSpan - 1)
            let h = cellH * CGFloat(zone.rowSpan) + miniGap * CGFloat(zone.rowSpan - 1)

            let cellRect = NSRect(x: x, y: y, width: w, height: h)
            let cellColor = isSelected
                ? NSColor.systemGreen.withAlphaComponent(0.35)
                : NSColor.secondaryLabelColor.withAlphaComponent(0.2)
            ctx.setFillColor(cellColor.cgColor)
            let path = CGPath(roundedRect: cellRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
        }

        // Label
        let label = layout.name as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let labelSize = label.size(withAttributes: attrs)
        let labelPoint = NSPoint(
            x: bounds.midX - labelSize.width / 2,
            y: 4
        )
        label.draw(at: labelPoint, withAttributes: attrs)
    }
}

// MARK: - Custom Grid Editor (merge cells)

class CustomGridEditor: NSView {
    var onApply: ((GridLayout) -> Void)?
    var onSaved: (() -> Void)?

    private var baseRows = 3
    private var baseCols = 3
    private var cellSelected: [[Bool]] = []
    private var mergedZones: [Zone] = []
    private var rowsStepper: NSStepper!
    private var colsStepper: NSStepper!
    private var rowsLabel: NSTextField!
    private var colsLabel: NSTextField!

    override init(frame: NSRect) {
        super.init(frame: frame)
        resetGrid()
        setupControls()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func resetGrid() {
        cellSelected = Array(repeating: Array(repeating: false, count: baseCols), count: baseRows)
        mergedZones = []
    }

    private func setupControls() {
        // Rows control
        let rl = NSTextField(labelWithString: "Rows:")
        rl.frame = NSRect(x: 20, y: bounds.height - 40, width: 40, height: 20)
        rl.autoresizingMask = [.minYMargin]
        addSubview(rl)

        rowsLabel = NSTextField(labelWithString: "\(baseRows)")
        rowsLabel.frame = NSRect(x: 62, y: bounds.height - 40, width: 20, height: 20)
        rowsLabel.autoresizingMask = [.minYMargin]
        addSubview(rowsLabel)

        rowsStepper = NSStepper(frame: NSRect(x: 82, y: bounds.height - 42, width: 20, height: 24))
        rowsStepper.minValue = 1; rowsStepper.maxValue = 5; rowsStepper.integerValue = baseRows
        rowsStepper.target = self; rowsStepper.action = #selector(gridSizeChanged(_:))
        rowsStepper.autoresizingMask = [.minYMargin]
        addSubview(rowsStepper)

        // Cols control
        let cl = NSTextField(labelWithString: "Cols:")
        cl.frame = NSRect(x: 120, y: bounds.height - 40, width: 35, height: 20)
        cl.autoresizingMask = [.minYMargin]
        addSubview(cl)

        colsLabel = NSTextField(labelWithString: "\(baseCols)")
        colsLabel.frame = NSRect(x: 157, y: bounds.height - 40, width: 20, height: 20)
        colsLabel.autoresizingMask = [.minYMargin]
        addSubview(colsLabel)

        colsStepper = NSStepper(frame: NSRect(x: 177, y: bounds.height - 42, width: 20, height: 24))
        colsStepper.minValue = 1; colsStepper.maxValue = 6; colsStepper.integerValue = baseCols
        colsStepper.target = self; colsStepper.action = #selector(gridSizeChanged(_:))
        colsStepper.autoresizingMask = [.minYMargin]
        addSubview(colsStepper)

        // Merge button
        let mergeBtn = NSButton(title: "Merge Selected", target: self, action: #selector(mergeSelected))
        mergeBtn.frame = NSRect(x: 220, y: bounds.height - 44, width: 120, height: 28)
        mergeBtn.bezelStyle = .rounded
        mergeBtn.autoresizingMask = [.minYMargin]
        addSubview(mergeBtn)

        // Reset button
        let resetBtn = NSButton(title: "Reset", target: self, action: #selector(resetClicked))
        resetBtn.frame = NSRect(x: 345, y: bounds.height - 44, width: 70, height: 28)
        resetBtn.bezelStyle = .rounded
        resetBtn.autoresizingMask = [.minYMargin]
        addSubview(resetBtn)

        // Apply button
        let applyBtn = NSButton(title: "Apply", target: self, action: #selector(applyClicked))
        applyBtn.frame = NSRect(x: 420, y: bounds.height - 44, width: 70, height: 28)
        applyBtn.bezelStyle = .rounded
        applyBtn.keyEquivalent = "\r"
        applyBtn.autoresizingMask = [.minYMargin]
        addSubview(applyBtn)
    }

    @objc private func gridSizeChanged(_ sender: NSStepper) {
        baseRows = rowsStepper.integerValue
        baseCols = colsStepper.integerValue
        rowsLabel.stringValue = "\(baseRows)"
        colsLabel.stringValue = "\(baseCols)"
        resetGrid()
        needsDisplay = true
    }

    @objc private func resetClicked() {
        resetGrid()
        needsDisplay = true
    }

    @objc private func mergeSelected() {
        // Find bounding box of selected cells
        var minR = baseRows, maxR = -1, minC = baseCols, maxC = -1
        for r in 0..<baseRows {
            for c in 0..<baseCols {
                if cellSelected[r][c] {
                    minR = min(minR, r); maxR = max(maxR, r)
                    minC = min(minC, c); maxC = max(maxC, c)
                }
            }
        }
        guard maxR >= minR && maxC >= minC else { return }

        // Check that all cells in the bounding box are selected (must be rectangular)
        var allSelected = true
        for r in minR...maxR {
            for c in minC...maxC {
                if !cellSelected[r][c] { allSelected = false }
            }
        }
        guard allSelected else {
            let alert = NSAlert()
            alert.messageText = "Selection must be rectangular"
            alert.informativeText = "Select a rectangular group of cells to merge."
            alert.runModal()
            return
        }

        // Check no overlap with existing merged zones
        for zone in mergedZones {
            let zoneMaxR = zone.row + zone.rowSpan - 1
            let zoneMaxC = zone.col + zone.colSpan - 1
            let overlapR = max(minR, zone.row) <= min(maxR, zoneMaxR)
            let overlapC = max(minC, zone.col) <= min(maxC, zoneMaxC)
            if overlapR && overlapC {
                let alert = NSAlert()
                alert.messageText = "Overlaps existing merged zone"
                alert.informativeText = "Undo or reset before merging overlapping areas."
                alert.runModal()
                return
            }
        }

        let zone = Zone(row: minR, col: minC, rowSpan: maxR - minR + 1, colSpan: maxC - minC + 1)
        mergedZones.append(zone)

        // Clear selection
        for r in 0..<baseRows { for c in 0..<baseCols { cellSelected[r][c] = false } }
        needsDisplay = true
    }

    @objc private func applyClicked() {
        // Ask user for a name
        let alert = NSAlert()
        alert.messageText = "Save Layout"
        alert.informativeText = "Give this layout a name to save it as a preset:"
        alert.addButton(withTitle: "Save & Apply")
        alert.addButton(withTitle: "Apply Without Saving")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        nameField.stringValue = "Custom (\(baseRows)×\(baseCols))"
        alert.accessoryView = nameField

        let response = alert.runModal()
        if response == .alertThirdButtonReturn { return }

        var layout = buildLayout()
        if response == .alertFirstButtonReturn {
            // Save with custom name
            let name = nameField.stringValue.isEmpty ? "Custom (\(baseRows)×\(baseCols))" : nameField.stringValue
            layout = GridLayout(name: name, baseRows: layout.baseRows, baseCols: layout.baseCols, zones: layout.zones)
            ConfigStore.shared.setActiveLayout(layout)
            onSaved?()
        }
        onApply?(layout)
    }

    private func buildLayout() -> GridLayout {
        // Start with merged zones, then fill remaining cells as 1×1
        var occupied = Array(repeating: Array(repeating: false, count: baseCols), count: baseRows)
        var allZones = mergedZones

        for zone in mergedZones {
            for r in zone.row..<(zone.row + zone.rowSpan) {
                for c in zone.col..<(zone.col + zone.colSpan) {
                    occupied[r][c] = true
                }
            }
        }

        for r in 0..<baseRows {
            for c in 0..<baseCols {
                if !occupied[r][c] {
                    allZones.append(Zone(row: r, col: c))
                }
            }
        }

        return GridLayout(name: "Custom (\(baseRows)×\(baseCols))", baseRows: baseRows, baseCols: baseCols, zones: allZones)
    }

    // MARK: - Drawing

    private func gridRect() -> NSRect {
        let inset: CGFloat = 20
        return NSRect(x: inset, y: 20, width: bounds.width - inset * 2, height: bounds.height - 80)
    }

    private func cellRect(row: Int, col: Int) -> NSRect {
        let area = gridRect()
        let gap: CGFloat = 4
        let cellW = (area.width - gap * CGFloat(baseCols + 1)) / CGFloat(baseCols)
        let cellH = (area.height - gap * CGFloat(baseRows + 1)) / CGFloat(baseRows)
        let x = area.origin.x + gap + CGFloat(col) * (cellW + gap)
        let y = area.origin.y + area.height - gap - CGFloat(row + 1) * (cellH + gap) + gap
        return NSRect(x: x, y: y, width: cellW, height: cellH)
    }

    private func zoneRect(zone: Zone) -> NSRect {
        let topLeft = cellRect(row: zone.row, col: zone.col)
        let bottomRight = cellRect(row: zone.row + zone.rowSpan - 1, col: zone.col + zone.colSpan - 1)
        return topLeft.union(bottomRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Background
        ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
        ctx.fill(bounds)

        // Draw occupied cells from merged zones
        var occupied = Array(repeating: Array(repeating: false, count: baseCols), count: baseRows)
        for zone in mergedZones {
            let rect = zoneRect(zone: zone)
            ctx.setFillColor(NSColor.systemGreen.withAlphaComponent(0.25).cgColor)
            let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.addPath(path); ctx.fillPath()
            ctx.setStrokeColor(NSColor.systemGreen.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(2)
            ctx.addPath(path); ctx.strokePath()

            for r in zone.row..<(zone.row + zone.rowSpan) {
                for c in zone.col..<(zone.col + zone.colSpan) {
                    occupied[r][c] = true
                }
            }
        }

        // Draw individual cells
        for r in 0..<baseRows {
            for c in 0..<baseCols {
                if occupied[r][c] { continue }
                let rect = cellRect(row: r, col: c)

                if cellSelected[r][c] {
                    ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.3).cgColor)
                } else {
                    ctx.setFillColor(NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor)
                }

                let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
                ctx.addPath(path); ctx.fillPath()

                ctx.setStrokeColor(NSColor.separatorColor.cgColor)
                ctx.setLineWidth(1)
                ctx.addPath(path); ctx.strokePath()
            }
        }
    }

    // MARK: - Mouse Handling

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        for r in 0..<baseRows {
            for c in 0..<baseCols {
                if cellRect(row: r, col: c).contains(point) {
                    // Check if it's in a merged zone — if so, ignore
                    var inMerged = false
                    for zone in mergedZones {
                        if r >= zone.row && r < zone.row + zone.rowSpan &&
                           c >= zone.col && c < zone.col + zone.colSpan {
                            inMerged = true; break
                        }
                    }
                    if !inMerged {
                        cellSelected[r][c].toggle()
                        needsDisplay = true
                    }
                    return
                }
            }
        }
    }
}
