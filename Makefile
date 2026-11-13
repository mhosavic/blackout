# Blackout: build, test, install
#
#   make test      run the test suite
#   make install   build, bundle and install the menu bar app and the CLI
#   make uninstall remove everything, including settings and the sudo rule

APP := .build/Blackout.app

.PHONY: build test bundle install uninstall icon

build:
	swift build -c release

test:
	swift run blackout-tests

# The menu bar app and the CLI in one bundle, so an install can never leave
# them at two different versions
bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/release/blackout-menu .build/release/blackout $(APP)/Contents/MacOS/
	cp Resources/Info.plist $(APP)/Contents/
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/
	codesign --force --sign - $(APP)

install: bundle
	$(APP)/Contents/MacOS/blackout install

uninstall:
	./uninstall.sh

# Redraw the app icon (only needed after changing scripts/make-icon.swift)
icon:
	swift scripts/make-icon.swift Resources/AppIcon.icns docs/logo.png
