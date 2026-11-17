.PHONY: build test app install clean

CONFIGURATION ?= release
SWIFT_FLAGS ?=
APP_DIR := build/Studio Switch.app

build:
	swift build -c $(CONFIGURATION) $(SWIFT_FLAGS)

test:
	@plugin="$$(dirname "$$(xcrun --find swiftc)")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"; \
	if [ -f "$$plugin" ]; then \
		swift test --disable-xctest --enable-swift-testing $(SWIFT_FLAGS) -Xswiftc -load-plugin-library -Xswiftc "$$plugin"; \
	else \
		swift test --disable-xctest --enable-swift-testing $(SWIFT_FLAGS); \
	fi

app: build
	mkdir -p "$(APP_DIR)/Contents/MacOS"
	cp "$$(swift build -c $(CONFIGURATION) $(SWIFT_FLAGS) --show-bin-path)/StudioSwitch" "$(APP_DIR)/Contents/MacOS/StudioSwitch"
	cp Info.plist "$(APP_DIR)/Contents/Info.plist"
	codesign --force --deep --sign - "$(APP_DIR)"

install: app
	ditto "$(APP_DIR)" "/Applications/Studio Switch.app"

clean:
	swift package clean
	rm -rf build
