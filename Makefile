APP_NAME = WindowGrid
BUILD_DIR = .build/release
APP_BUNDLE = $(APP_NAME).app
INSTALL_DIR = /Applications

.PHONY: build release app install clean run

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
	@echo "$(APP_BUNDLE) created successfully."

install: app
	@echo "Installing to $(INSTALL_DIR)..."
	@cp -R $(APP_BUNDLE) $(INSTALL_DIR)/
	@echo "Installed. Launch from Applications or Spotlight."

clean:
	swift package clean
	rm -rf $(APP_BUNDLE)

run: build
	.build/debug/$(APP_NAME)
