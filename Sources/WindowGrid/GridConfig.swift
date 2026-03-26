import Foundation
import AppKit

// MARK: - Scene (记忆布局)

struct ZoneAssignment: Codable {
    let zoneIndex: Int
    let appBundleID: String
    let appName: String
    var windowURL: String?       // for browsers: the URL of the active tab
    var allTabURLs: [String]?    // for browsers: all tab URLs in this window
}

struct WindowScene: Codable {
    let name: String
    let layoutName: String
    let assignments: [ZoneAssignment]
}

// MARK: - Zone

/// A single zone in the grid, defined by its position and span in the base grid.
struct Zone: Codable, Equatable {
    let row: Int
    let col: Int
    let rowSpan: Int
    let colSpan: Int

    init(row: Int, col: Int, rowSpan: Int = 1, colSpan: Int = 1) {
        self.row = row
        self.col = col
        self.rowSpan = rowSpan
        self.colSpan = colSpan
    }
}

struct GridLayout: Codable, Equatable {
    let name: String
    let baseRows: Int
    let baseCols: Int
    let gaps: CGFloat
    let zones: [Zone]

    static func == (lhs: GridLayout, rhs: GridLayout) -> Bool {
        lhs.name == rhs.name
    }

    /// Convenience: create a uniform grid where every cell is its own zone
    init(name: String, rows: Int, cols: Int, gaps: CGFloat = 6) {
        self.name = name
        self.baseRows = rows
        self.baseCols = cols
        self.gaps = gaps
        var z: [Zone] = []
        for r in 0..<rows {
            for c in 0..<cols {
                z.append(Zone(row: r, col: c))
            }
        }
        self.zones = z
    }

    /// Full initializer with custom zones
    init(name: String, baseRows: Int, baseCols: Int, gaps: CGFloat = 6, zones: [Zone]) {
        self.name = name
        self.baseRows = baseRows
        self.baseCols = baseCols
        self.gaps = gaps
        self.zones = zones
    }

    // MARK: - Presets

    static let sixGrid = GridLayout(name: "6-Grid (3×2)", rows: 2, cols: 3)
    static let fourGrid = GridLayout(name: "4-Grid (2×2)", rows: 2, cols: 2)
    static let threeCol = GridLayout(name: "3-Column", rows: 1, cols: 3)
    static let twoCol = GridLayout(name: "2-Column", rows: 1, cols: 2)
    static let nineGrid = GridLayout(name: "9-Grid (3×3)", rows: 3, cols: 3)

    /// 1 tall left + 4 right (2×2)
    static let tallLeft4 = GridLayout(
        name: "1+4 (Tall Left)",
        baseRows: 2, baseCols: 3,
        zones: [
            Zone(row: 0, col: 0, rowSpan: 2, colSpan: 1),
            Zone(row: 0, col: 1), Zone(row: 0, col: 2),
            Zone(row: 1, col: 1), Zone(row: 1, col: 2),
        ]
    )

    /// 4 left (2×2) + 1 tall right
    static let tallRight4 = GridLayout(
        name: "4+1 (Tall Right)",
        baseRows: 2, baseCols: 3,
        zones: [
            Zone(row: 0, col: 0), Zone(row: 0, col: 1),
            Zone(row: 1, col: 0), Zone(row: 1, col: 1),
            Zone(row: 0, col: 2, rowSpan: 2, colSpan: 1),
        ]
    )

    /// Top wide + 2 bottom
    static let wideTop2 = GridLayout(
        name: "1+2 (Wide Top)",
        baseRows: 2, baseCols: 2,
        zones: [
            Zone(row: 0, col: 0, rowSpan: 1, colSpan: 2),
            Zone(row: 1, col: 0), Zone(row: 1, col: 1),
        ]
    )

    /// 2 top + wide bottom
    static let wideBottom2 = GridLayout(
        name: "2+1 (Wide Bottom)",
        baseRows: 2, baseCols: 2,
        zones: [
            Zone(row: 0, col: 0), Zone(row: 0, col: 1),
            Zone(row: 1, col: 0, rowSpan: 1, colSpan: 2),
        ]
    )

    static let allPresets: [GridLayout] = [
        sixGrid, fourGrid, nineGrid, threeCol, twoCol,
        tallLeft4, tallRight4, wideTop2, wideBottom2,
    ]

    // MARK: - Zone Rect Calculation

    func zoneRects(in screenFrame: NSRect) -> [(zone: Int, rect: NSRect)] {
        let totalGapW = gaps * CGFloat(baseCols + 1)
        let totalGapH = gaps * CGFloat(baseRows + 1)
        let cellW = (screenFrame.width - totalGapW) / CGFloat(baseCols)
        let cellH = (screenFrame.height - totalGapH) / CGFloat(baseRows)

        var result: [(zone: Int, rect: NSRect)] = []

        for (index, zone) in zones.enumerated() {
            let x = screenFrame.origin.x + gaps + CGFloat(zone.col) * (cellW + gaps)
            // macOS y is bottom-up; row 0 = top of screen
            let topY = screenFrame.origin.y + screenFrame.height
            let y = topY - gaps - CGFloat(zone.row + zone.rowSpan) * (cellH + gaps) + gaps

            let w = cellW * CGFloat(zone.colSpan) + gaps * CGFloat(zone.colSpan - 1)
            let h = cellH * CGFloat(zone.rowSpan) + gaps * CGFloat(zone.rowSpan - 1)

            result.append((zone: index, rect: NSRect(x: x, y: y, width: w, height: h)))
        }
        return result
    }

    func zoneAt(point: NSPoint, in screenFrame: NSRect) -> (zone: Int, rect: NSRect)? {
        let rects = zoneRects(in: screenFrame)
        // Direct hit
        for z in rects {
            if z.rect.contains(point) {
                return z
            }
        }
        // Nearest
        var nearest: (zone: Int, rect: NSRect)?
        var minDist: CGFloat = .greatestFiniteMagnitude
        for z in rects {
            let dist = hypot(point.x - z.rect.midX, point.y - z.rect.midY)
            if dist < minDist {
                minDist = dist
                nearest = z
            }
        }
        return nearest
    }
}
