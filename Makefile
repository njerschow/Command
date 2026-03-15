.PHONY: build app run clean dev test dist

# Development build and run (debug, faster compilation)
dev:
	swift build
	swift run

# Release build
build:
	swift build -c release

# Run tests
test:
	swift test

# Create .app bundle
app: build
	@mkdir -p build/Command.app/Contents/MacOS
	@mkdir -p build/Command.app/Contents/Resources
	@cp .build/release/Command build/Command.app/Contents/MacOS/
	@cp Info.plist build/Command.app/Contents/
	@cp Resources/AppIcon.icns build/Command.app/Contents/Resources/ 2>/dev/null || true
	@codesign --force --deep --sign - build/Command.app
	@echo "Built build/Command.app"

# Create distributable zip
dist: app
	@xattr -cr build/Command.app
	@cd build && ditto -c -k --keepParent Command.app Command.zip
	@echo "Created build/Command.zip ($(du -h build/Command.zip | cut -f1))"

# Build and launch .app
run: app
	open build/Command.app

# Clean all build artifacts
clean:
	swift package clean
	rm -rf build
