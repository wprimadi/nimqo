# NIMQO: build, run, and package. The scripts in scripts/ do the work.
#   make run     build (Debug) and open the app
#   make build   build the app (Debug); CONFIG=Release for an optimised one
#   make dmg     build Release and package it as dist/NIMQO-<version>.dmg
#   make test    build and run the app's unit tests

CONFIG ?= Debug
APP     = app/build/Build/Products/$(CONFIG)/NIMQO.app
RELEASE = app/build/Build/Products/Release/NIMQO.app
STAGE   = dist/.stage

.PHONY: run build dmg test clean

build:
	CONFIG=$(CONFIG) ./scripts/build-app.sh

run: build
	open "$(APP)"

test:
	./scripts/build-app.sh test

# The app beside a link to Applications, to drag it across.
dmg:
	CONFIG=Release ./scripts/build-app.sh
	rm -rf dist/.stage
	mkdir -p dist/.stage
	ditto "$(RELEASE)" "$(STAGE)/NIMQO.app"
	ln -s /Applications "$(STAGE)/Applications"
	@version=$$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$(RELEASE)/Contents/Info.plist"); \
	rm -f "dist/NIMQO-$$version.dmg"; \
	hdiutil create -quiet -volname "NIMQO $$version" -srcfolder "$(STAGE)" \
		-fs HFS+ -format UDZO "dist/NIMQO-$$version.dmg" && \
	echo "dmg ready: dist/NIMQO-$$version.dmg"
	rm -rf dist/.stage

clean:
	rm -rf app/build app/Generated dist
