APP_NAME = WindowGrid
APP_BUNDLE = $(APP_NAME).app
INSTALL_DIR = /Applications
DIST_DIR = dist
DMG_ROOT = $(DIST_DIR)/dmgroot
DMG_NAME = $(APP_NAME)-macOS.dmg
DMG_PATH = $(DIST_DIR)/$(DMG_NAME)
PROJECT_FILE = $(APP_NAME).xcodeproj
SCHEME = $(APP_NAME)
CONFIGURATION ?= Release
XCODE_DERIVED_DATA = .build/xcode
XCODE_BUILD_APP = $(XCODE_DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_BUNDLE)
ARCHIVE_PATH = $(DIST_DIR)/$(APP_NAME).xcarchive
ARCHIVE_APP = $(ARCHIVE_PATH)/Products/Applications/$(APP_BUNDLE)
APPCAST_WORK_DIR = $(DIST_DIR)/appcast
APPCAST_PATH = site/appcast.xml
MARKETING_VERSION ?= 0.1.1
CURRENT_PROJECT_VERSION ?= 2
APPCAST_DOWNLOAD_URL_PREFIX ?= https://github.com/Liko0223/WindowGrid/releases/download/v$(MARKETING_VERSION)/
APPLE_DEVELOPMENT_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F\" '/Apple Development/ {print $$2; exit}')
DEVELOPER_ID_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F\" '/Developer ID Application/ {print $$2; exit}')
DEVELOPMENT_TEAM ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {split($$0, q, "\""); split(q[2], parts, " "); team=parts[length(parts)]; print substr(team, 2, length(team)-2); exit}')
DISTRIBUTION_TEAM ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk '/Developer ID Application/ {split($$0, q, "\""); split(q[2], parts, " "); team=parts[length(parts)]; print substr(team, 2, length(team)-2); exit}')
CODE_SIGN_IDENTITY ?= $(APPLE_DEVELOPMENT_IDENTITY)
DISTRIBUTION_SIGN_IDENTITY ?= $(DEVELOPER_ID_IDENTITY)
REQUIRE_CODE_SIGN ?= 0
NOTARY_PROFILE ?=
SPARKLE_BIN_DIR ?= $(shell find "$(HOME)/Library/Developer/Xcode/DerivedData" -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin" -type d -print -quit 2>/dev/null)
SPARKLE_GENERATE_KEYS ?= $(SPARKLE_BIN_DIR)/generate_keys
SPARKLE_GENERATE_APPCAST ?= $(SPARKLE_BIN_DIR)/generate_appcast

.PHONY: generate-project resolve-packages build release app archive-app codesign-release-app install dev-dmg package-dmg dmg notarize release-dmg appcast sparkle-generate-keys signing-check release-check verify-dmg relaunch clean run

generate-project:
	xcodegen generate

resolve-packages: generate-project
	xcodebuild -resolvePackageDependencies -project "$(PROJECT_FILE)" -scheme "$(SCHEME)"

build: generate-project
	xcodebuild -project "$(PROJECT_FILE)" -scheme "$(SCHEME)" -configuration Debug -derivedDataPath "$(XCODE_DERIVED_DATA)" build \
		CURRENT_PROJECT_VERSION="$(CURRENT_PROJECT_VERSION)" \
		MARKETING_VERSION="$(MARKETING_VERSION)" \
		CODE_SIGN_STYLE=Manual \
		CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)"

release: generate-project
	xcodebuild -project "$(PROJECT_FILE)" -scheme "$(SCHEME)" -configuration Release -derivedDataPath "$(XCODE_DERIVED_DATA)" build \
		CURRENT_PROJECT_VERSION="$(CURRENT_PROJECT_VERSION)" \
		MARKETING_VERSION="$(MARKETING_VERSION)" \
		CODE_SIGN_STYLE=Manual \
		CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)"

app: release
	@echo "Creating $(APP_BUNDLE)..."
	@rm -rf $(APP_BUNDLE)
	@cp -R "$(XCODE_BUILD_APP)" "$(APP_BUNDLE)"
	@codesign --verify --deep --strict --verbose=2 "$(APP_BUNDLE)"
	@echo "$(APP_BUNDLE) created successfully."

archive-app: generate-project signing-check
	@echo "Archiving $(APP_NAME) with $(DISTRIBUTION_SIGN_IDENTITY)..."
	@rm -rf "$(ARCHIVE_PATH)" "$(APP_BUNDLE)"
	xcodebuild archive -project "$(PROJECT_FILE)" -scheme "$(SCHEME)" -configuration Release -archivePath "$(ARCHIVE_PATH)" \
		CURRENT_PROJECT_VERSION="$(CURRENT_PROJECT_VERSION)" \
		MARKETING_VERSION="$(MARKETING_VERSION)" \
		CODE_SIGN_STYLE=Manual \
		CODE_SIGN_IDENTITY="$(DISTRIBUTION_SIGN_IDENTITY)" \
		SKIP_INSTALL=NO
	@cp -R "$(ARCHIVE_APP)" "$(APP_BUNDLE)"
	@$(MAKE) codesign-release-app DISTRIBUTION_SIGN_IDENTITY="$(DISTRIBUTION_SIGN_IDENTITY)"
	@codesign --verify --deep --strict --verbose=2 "$(APP_BUNDLE)"
	@echo "$(APP_BUNDLE) archived successfully."

codesign-release-app:
	@echo "Re-signing embedded Sparkle tools with $(DISTRIBUTION_SIGN_IDENTITY)..."
	@set -e; \
	sparkle_framework="$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework"; \
	if [ -d "$$sparkle_framework" ]; then \
		codesign --force --options runtime --timestamp --sign "$(DISTRIBUTION_SIGN_IDENTITY)" "$$sparkle_framework/Versions/B/XPCServices/Downloader.xpc"; \
		codesign --force --options runtime --timestamp --sign "$(DISTRIBUTION_SIGN_IDENTITY)" "$$sparkle_framework/Versions/B/XPCServices/Installer.xpc"; \
		codesign --force --options runtime --timestamp --sign "$(DISTRIBUTION_SIGN_IDENTITY)" "$$sparkle_framework/Versions/B/Updater.app"; \
		codesign --force --options runtime --timestamp --sign "$(DISTRIBUTION_SIGN_IDENTITY)" "$$sparkle_framework/Versions/B/Autoupdate"; \
		codesign --force --options runtime --timestamp --sign "$(DISTRIBUTION_SIGN_IDENTITY)" "$$sparkle_framework"; \
	fi
	@codesign --force --options runtime --timestamp --sign "$(DISTRIBUTION_SIGN_IDENTITY)" "$(APP_BUNDLE)"

install: app
	@echo "Installing to $(INSTALL_DIR)..."
	@cp -R $(APP_BUNDLE) $(INSTALL_DIR)/
	@echo "Installed. Launch from Applications or Spotlight."

dev-dmg: app package-dmg

package-dmg:
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

dmg: CODE_SIGN_IDENTITY = $(DISTRIBUTION_SIGN_IDENTITY)
dmg: REQUIRE_CODE_SIGN = 1
dmg: archive-app package-dmg

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

release-dmg: notarize appcast

appcast: resolve-packages
	@if [ ! -x "$(SPARKLE_GENERATE_APPCAST)" ]; then \
		echo "Sparkle generate_appcast not found. Run 'make resolve-packages' first."; \
		exit 1; \
	fi
	@if [ ! -f "$(DMG_PATH)" ]; then \
		echo "Missing $(DMG_PATH). Run 'make release-dmg' or 'make notarize' first."; \
		exit 1; \
	fi
	@rm -rf "$(APPCAST_WORK_DIR)"
	@mkdir -p "$(APPCAST_WORK_DIR)" "$(dir $(APPCAST_PATH))"
	@cp "$(DMG_PATH)" "$(APPCAST_WORK_DIR)/$(DMG_NAME)"
	@if [ -f "docs/release-notes/$(MARKETING_VERSION).md" ]; then \
		cp "docs/release-notes/$(MARKETING_VERSION).md" "$(APPCAST_WORK_DIR)/$(APP_NAME)-macOS.md"; \
	fi
	@(cd "$(APPCAST_WORK_DIR)" && "$(SPARKLE_GENERATE_APPCAST)" --download-url-prefix "$(APPCAST_DOWNLOAD_URL_PREFIX)" -o appcast.xml ".")
	@cp "$(APPCAST_WORK_DIR)/appcast.xml" "$(APPCAST_PATH)"
	@echo "$(APPCAST_PATH) generated successfully."

sparkle-generate-keys: resolve-packages
	@if [ ! -x "$(SPARKLE_GENERATE_KEYS)" ]; then \
		echo "Sparkle generate_keys not found. Run 'make resolve-packages' first."; \
		exit 1; \
	fi
	@"$(SPARKLE_GENERATE_KEYS)"

signing-check:
	@echo "Checking release signing prerequisites..."
	@if [ -z "$(DISTRIBUTION_SIGN_IDENTITY)" ]; then \
		echo "✗ Missing Developer ID Application signing identity."; \
		echo "  Install it from Xcode: Settings > Accounts > Manage Certificates > + > Developer ID Application"; \
		exit 1; \
	else \
		echo "✓ Developer ID identity: $(DISTRIBUTION_SIGN_IDENTITY)"; \
	fi

release-check: signing-check
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
