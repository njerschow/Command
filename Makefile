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
	@echo "Built build/Command.app"

# Create distributable zip
dist: app
	@cd build && zip -r Command.zip Command.app
	@echo "Created build/Command.zip ($(du -h build/Command.zip | cut -f1))"

# Build and launch .app
run: app
	open build/Command.app

# Clean all build artifacts
clean:
	swift package clean
	rm -rf build
