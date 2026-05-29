# Sparkle Updates

WindowGrid uses Sparkle 2 for in-app updates.

## One-time setup

The Sparkle EdDSA signing key was generated with:

```bash
make sparkle-generate-keys
```

The private key is stored in the local login Keychain. The public key is stored in `Resources/Info.plist` as `SUPublicEDKey`.

## Release flow

Use a monotonically increasing `CURRENT_PROJECT_VERSION` for every public update. Sparkle compares this value, not the marketing version alone.

```bash
make release-check NOTARY_PROFILE=windowgrid-notary
make release-dmg \
  NOTARY_PROFILE=windowgrid-notary \
  MARKETING_VERSION=0.1.1 \
  CURRENT_PROJECT_VERSION=4
```

`make release-dmg` will:

1. Generate `WindowGrid.xcodeproj` from `project.yml`.
2. Build a Developer ID signed Xcode archive so Sparkle helper tools are signed correctly.
3. Create, sign, notarize, and staple `dist/WindowGrid-macOS.dmg`.
4. Generate `site/appcast.xml` with the Sparkle EdDSA signature.

Upload the DMG to the matching immutable GitHub Release tag:

```bash
gh release upload v0.1.1 dist/WindowGrid-macOS.dmg --clobber
wrangler pages deploy site --project-name windowgrid
```

The app reads updates from:

```text
https://windowgrid.pages.dev/appcast.xml
```

The generated appcast points at:

```text
https://github.com/Liko0223/WindowGrid/releases/download/v<MARKETING_VERSION>/WindowGrid-macOS.dmg
```

## Local checks

```bash
make app
codesign --verify --deep --strict --verbose=2 WindowGrid.app
plutil -p WindowGrid.app/Contents/Info.plist | rg 'SU|CFBundle'
```

Sparkle checks automatically on its regular schedule and WindowGrid also starts a background check shortly after launch. For manual testing, use `Settings > Check for Updates...`.
