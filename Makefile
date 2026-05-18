APP_NAME = WindowGrid
BUILD_DIR = .build/release
APP_BUNDLE = $(APP_NAME).app
INSTALL_DIR = /Applications
DIST_DIR = dist
DMG_ROOT = $(DIST_DIR)/dmgroot
DMG_NAME = $(APP_NAME)-macOS.dmg
DMG_PATH = $(DIST_DIR)/$(DMG_NAME)
CODE_SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F\" '/Developer ID Application/ {found=$$2; print found; exit} /Apple Development/ && !fallback {fallback=$$2} END {if (!found && fallback) print fallback}')
NOTARY_PROFILE ?=

.PHONY: build release app install dmg notarize relaunch clean run

build:
	swift build

release:
	swift build -c release

app: release
	@echo "Creating $(APP_BUNDLE)..."
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	@cp Resources/Info.plist $(APP_BUNDLE)/Contents/
	@cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/ 2>/dev/null || true
	@if [ -n "$(CODE_SIGN_IDENTITY)" ]; then \
		echo "Signing $(APP_BUNDLE) with $(CODE_SIGN_IDENTITY)..."; \
		codesign --force --deep --sign "$(CODE_SIGN_IDENTITY)" "$(APP_BUNDLE)"; \
	else \
		echo "No Apple Development signing identity found; using ad-hoc signing."; \
		codesign --force --deep --sign - "$(APP_BUNDLE)"; \
	fi
	@echo "$(APP_BUNDLE) created successfully."

install: app
	@echo "Installing to $(INSTALL_DIR)..."
	@cp -R $(APP_BUNDLE) $(INSTALL_DIR)/
	@echo "Installed. Launch from Applications or Spotlight."

dmg: app
	@echo "Creating $(DMG_PATH)..."
	@rm -rf "$(DMG_ROOT)" "$(DMG_PATH)"
	@mkdir -p "$(DMG_ROOT)"
	@cp -R "$(APP_BUNDLE)" "$(DMG_ROOT)/"
	@ln -s /Applications "$(DMG_ROOT)/Applications"
	@mkdir -p "$(DIST_DIR)"
	@hdiutil create -volname "$(APP_NAME)" -srcfolder "$(DMG_ROOT)" -ov -format UDZO "$(DMG_PATH)"
	@if [ -n "$(CODE_SIGN_IDENTITY)" ]; then \
		echo "Signing $(DMG_PATH) with $(CODE_SIGN_IDENTITY)..."; \
		codesign --force --sign "$(CODE_SIGN_IDENTITY)" "$(DMG_PATH)"; \
	fi
	@rm -rf "$(DMG_ROOT)"
	@echo "$(DMG_PATH) created successfully."

notarize: dmg
	@if [ -z "$(NOTARY_PROFILE)" ]; then \
		echo "Set NOTARY_PROFILE to an xcrun notarytool keychain profile."; \
		echo "Example: xcrun notarytool store-credentials windowgrid-notary --apple-id you@example.com --team-id TEAMID --password app-specific-password"; \
		echo "Then run: make notarize NOTARY_PROFILE=windowgrid-notary"; \
		exit 1; \
	fi
	@echo "Submitting $(DMG_PATH) for notarization..."
	@xcrun notarytool submit "$(DMG_PATH)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	@echo "Stapling notarization ticket..."
	@xcrun stapler staple "$(DMG_PATH)"
	@spctl --assess --type open --context context:primary-signature --verbose "$(DMG_PATH)"
	@echo "$(DMG_PATH) notarized successfully."

relaunch: install
	@echo "Relaunching $(INSTALL_DIR)/$(APP_BUNDLE)..."
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@open -n "$(INSTALL_DIR)/$(APP_BUNDLE)"

clean:
	swift package clean
	rm -rf $(APP_BUNDLE) $(DIST_DIR)

run: build
	.build/debug/$(APP_NAME)
