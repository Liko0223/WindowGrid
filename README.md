<p align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="WindowGrid Icon">
</p>

<h1 align="center">WindowGrid</h1>

<p align="center">Open-source window management for macOS. Hold <b>Option</b> and drag any window to snap it into a grid zone.</p>

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## Features

- **Drag to snap** — Hold Option + drag a window, release to snap it into a grid zone
- **Grid overlay** — Semi-transparent grid appears while dragging, highlights the target zone
- **Multiple layouts** — 6-Grid (3×2), 4-Grid (2×2), 3-Column, 2-Column
- **Menu bar app** — Switch layouts from the menu bar, no dock icon clutter
- **Launch at login** — Start automatically when you log in
- **Ultrawide optimized** — Designed for 21:9 and 32:9 ultrawide monitors
- **Zero dependencies** — Pure Swift + AppKit, no third-party libraries
- **Lightweight** — Minimal CPU and memory usage

## Install

### Homebrew (coming soon)

```bash
brew install --cask windowgrid
```

### Build from source

```bash
git clone https://github.com/yourusername/WindowGrid.git
cd WindowGrid
make install
```

This builds a release binary, packages it as `WindowGrid.app`, and copies it to `/Applications`.

## Usage

1. Launch WindowGrid — it appears as a grid icon in the menu bar
2. **Hold Option** and **drag any window** by its title bar
3. A grid overlay appears on screen
4. Move to the desired zone (it highlights blue)
5. **Release the mouse** — the window snaps into place

### Switch layouts

Click the menu bar icon to switch between:
- **6-Grid (3×2)** — ideal for ultrawide monitors
- **4-Grid (2×2)** — classic quadrants
- **3-Column** — for side-by-side workflows
- **2-Column** — simple split

## Requirements

- macOS 13 (Ventura) or later
- **Accessibility permission** — WindowGrid needs this to move and resize windows. You'll be prompted on first launch.

## Configuration

Config file is at `~/.config/windowgrid/config.json`. You can edit it to add custom layouts with custom column/row proportions.

## Building

```bash
make build      # Debug build
make release    # Release build
make app        # Package as .app
make install    # Install to /Applications
make run        # Build and run (debug)
make clean      # Clean build artifacts
```

## License

MIT
