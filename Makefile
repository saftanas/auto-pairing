.PHONY: build app install clean

CONFIGURATION ?= release
APP_DIR := build/Studio Switch.app

build:
	swift build -c $(CONFIGURATION)

app: build
	mkdir -p "$(APP_DIR)/Contents/MacOS"
	cp .build/$(CONFIGURATION)/StudioSwitch "$(APP_DIR)/Contents/MacOS/StudioSwitch"
	cp Info.plist "$(APP_DIR)/Contents/Info.plist"
	codesign --force --deep --sign - "$(APP_DIR)"

install: app
	ditto "$(APP_DIR)" "/Applications/Studio Switch.app"

clean:
	swift package clean
	rm -rf build
