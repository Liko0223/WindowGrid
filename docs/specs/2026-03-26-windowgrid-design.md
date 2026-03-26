# WindowGrid Design Spec

## Product
Open-source macOS window management tool. Drag-to-snap with grid overlay, optimized for ultrawide monitors.

## Core Interaction
1. User holds **Option** + drags a window
2. Semi-transparent grid overlay appears on screen
3. Zone under cursor highlights
4. Mouse up → window snaps to that zone
5. Release Option or stop dragging → overlay disappears

## Layout System
- Preset templates: 6-grid (3×2), 4-grid (2×2), 3-column, 2-column
- Users can adjust column/row proportions (e.g., left column 40%, right two 30% each)
- Config stored as JSON in `~/.config/windowgrid/config.json`

## Architecture

| Module | Responsibility |
|--------|---------------|
| AppDelegate | Menu bar entry, lifecycle |
| EventMonitor | Global Option + mouse drag detection |
| OverlayWindow | Borderless transparent window, draws grid + highlight |
| WindowSnapper | Accessibility API to get/set window position & size |
| GridLayoutEngine | Layout calculation, template management, proportion adjustment |
| PreferencesWindow | Settings UI (AppKit), template picker + proportion sliders |
| ConfigStore | JSON config read/write at `~/.config/windowgrid/` |

## Tech Stack
- Pure Swift + AppKit, zero dependencies
- Accessibility API (AXUIElement) for window manipulation
- NSEvent.addGlobalMonitorForEvents for global event monitoring
- Menu bar resident, no Dock icon
- macOS 13+ (Ventura)

## MVP Scope
- 4 preset templates
- Option + drag triggers snap
- Menu bar layout switching
- Grid overlay with fade animation
- First-launch accessibility permission prompt

## Out of MVP
- Multi-monitor independent layouts
- Visual proportion editor UI (JSON config first)
- Keyboard shortcut snapping
- Window memory/restore
