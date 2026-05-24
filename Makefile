APP_NAME = WindowGrid
BUILD_DIR = .build/release
APP_BUNDLE = $(APP_NAME).app
INSTALL_DIR = /Applications
DIST_DIR = dist
DMG_ROOT = $(DIST_DIR)/dmgroot
DMG_NAME = $(APP_NAME)-macOS.dmg
DMG_PATH = $(DIST_DIR)/$(DMG_NAME)
APPLE_DEVELOPMENT_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F\" '/Apple Development/ {print $$2; exit}')
DEVELOPER_ID_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F\" '/Developer ID Application/ {print $$2; exit}')
CODE_SIGN_IDENTITY ?= $(APPLE_DEVELOPMENT_IDENTITY)
DISTRIBUTION_SIGN_IDENTITY ?= $(DEVELOPER_ID_IDENTITY)
REQUIRE_CODE_SIGN ?= 0
NOTARY_PROFILE ?=

.PHONY: build release app install dev-dmg dmg notarize release-dmg release-check verify-dmg relaunch clean run

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
		codesign --force --deep --options runtime --timestamp --sign "$(CODE_SIGN_IDENTITY)" "$(APP_BUNDLE)"; \
	elif [ "$(REQUIRE_CODE_SIGN)" = "1" ]; then \
		echo "No required code signing identity found."; \
		exit 1; \
	else \
		echo "No code signing identity found; using ad-hoc signing."; \
		codesign --force --deep --sign - "$(APP_BUNDLE)"; \
	fi
	@codesign --verify --deep --strict --verbose=2 "$(APP_BUNDLE)"
	@echo "$(APP_BUNDLE) created successfully."

install: app
	@echo "Installing to $(INSTALL_DIR)..."
	@cp -R $(APP_BUNDLE) $(INSTALL_DIR)/
	@echo "Installed. Launch from Applications or Spotlight."

dev-dmg: app
	@echo "Creating $(DMG_PATH)..."
	@rm -rf "$(DMG_ROOT)" "$(DMG_PATH)"
	@mkdir -p "$(DMG_ROOT)"
	@cp -R "$(APP_BUNDLE)" "$(DMG_ROOT)/"
	@ln -s /Applications "$(DMG_ROOT)/Applications"
	@mkdir -p "$(DIST_DIR)"
	@hdiutil create -volname "$(APP_NAME)" -srcfolder "$(DMG_ROOT)" -ov -format UDZO "$(DMG_PATH)"
	@if [ -n "$(CODE_SIGN_IDENTITY)" ]; then \
		echo "Signing $(DMG_PATH) with $(CODE_SIGN_IDENTITY)..."; \
		codesign --force --timestamp --sign "$(CODE_SIGN_IDENTITY)" "$(DMG_PATH)"; \
	fi
	@rm -rf "$(DMG_ROOT)"
	@echo "$(DMG_PATH) created successfully."

dmg:
	@if [ -z "$(DISTRIBUTION_SIGN_IDENTITY)" ]; then \
		echo "No Developer ID Application signing identity found."; \
		echo "Install a Developer ID Application certificate, or pass DISTRIBUTION_SIGN_IDENTITY='Developer ID Application: ...'."; \
		exit 1; \
	fi
	@$(MAKE) dev-dmg CODE_SIGN_IDENTITY="$(DISTRIBUTION_SIGN_IDENTITY)" REQUIRE_CODE_SIGN=1

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
	@xcrun stapler validate "$(DMG_PATH)"
	@spctl --assess --type open --context context:primary-signature --verbose "$(DMG_PATH)"
	@echo "$(DMG_PATH) notarized successfully."

release-dmg: notarize

release-check:
	@echo "Checking release signing prerequisites..."
	@if [ -z "$(DISTRIBUTION_SIGN_IDENTITY)" ]; then \
		echo "✗ Missing Developer ID Application signing identity."; \
		echo "  Install it from Xcode: Settings > Accounts > Manage Certificates > + > Developer ID Application"; \
		exit 1; \
	else \
		echo "✓ Developer ID identity: $(DISTRIBUTION_SIGN_IDENTITY)"; \
	fi
	@if [ -z "$(NOTARY_PROFILE)" ]; then \
		echo "✗ Missing NOTARY_PROFILE."; \
		echo "  Example: make release-check NOTARY_PROFILE=windowgrid-notary"; \
		exit 1; \
	fi
	@xcrun notarytool history --keychain-profile "$(NOTARY_PROFILE)" >/dev/null 2>&1 || { \
		echo "✗ Notary profile '$(NOTARY_PROFILE)' is not available or not valid."; \
		echo "  Create it with: xcrun notarytool store-credentials $(NOTARY_PROFILE) --apple-id you@example.com --team-id TEAMID --password app-specific-password"; \
		exit 1; \
	}
	@echo "✓ Notary profile: $(NOTARY_PROFILE)"

verify-dmg:
	@codesign --verify --verbose=2 "$(DMG_PATH)"
	@spctl --assess --type open --context context:primary-signature --verbose "$(DMG_PATH)"
	@xcrun stapler validate "$(DMG_PATH)"

relaunch: install
	@echo "Relaunching $(INSTALL_DIR)/$(APP_BUNDLE)..."
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@open -n "$(INSTALL_DIR)/$(APP_BUNDLE)"

clean:
	swift package clean
	rm -rf $(APP_BUNDLE) $(DIST_DIR)

run: build
	.build/debug/$(APP_NAME)
