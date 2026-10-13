.PHONY: build test app universal dmg install run clean icon

build:
	swift build

test:
	swift test

app:
	scripts/bundle.sh

universal:
	UNIVERSAL=1 scripts/bundle.sh

dmg:
	UNIVERSAL=1 DMG=1 scripts/bundle.sh

# Installs into /Applications (macOS ties Accessibility to the app's location).
install: app
	rm -rf /Applications/Roller.app
	cp -R build/Roller.app /Applications/
	@echo "Installed /Applications/Roller.app. Open it, then allow Accessibility when asked."
	@echo "Command line tool: ln -sf /Applications/Roller.app/Contents/Resources/bin/roller /usr/local/bin/roller"

run: app
	open build/Roller.app

icon:
	swift scripts/make-icon.swift

clean:
	rm -rf .build build
