.PHONY: build app run clean dev

# Development build and run (debug, faster compilation)
dev:
	swift build
	swift run

# Release build
build:
	swift build -c release

# Create .app bundle
app: build
	@mkdir -p build/Command.app/Contents/MacOS
	@mkdir -p build/Command.app/Contents/Resources
	@cp .build/release/Command build/Command.app/Contents/MacOS/
	@cp Info.plist build/Command.app/Contents/
	@echo "Built build/Command.app"

# Build and launch .app
run: app
	open build/Command.app

# Clean all build artifacts
clean:
	swift package clean
	rm -rf build
