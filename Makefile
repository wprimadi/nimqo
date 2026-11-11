# NIMQO: build, run, and package. The scripts in scripts/ do the work.
#   make run             build (Debug) and open the app
#   make build           build the app (Debug); CONFIG=Release for an optimised one
#   make dmg             all three disk images below, in dist/
#   make dmg-silicon     Release for Apple silicon: dist/NIMQO-<version>-apple-silicon.dmg
#   make dmg-intel       Release for Intel Macs:    dist/NIMQO-<version>-intel.dmg
#   make dmg-universal   Release for both:          dist/NIMQO-<version>-universal.dmg
#   make test            build and run the app's unit tests

CONFIG ?= Debug
APP     = app/build/Build/Products/$(CONFIG)/NIMQO.app
RELEASE = app/build/Build/Products/Release/NIMQO.app
STAGE   = dist/.stage

.PHONY: run build dmg dmg-silicon dmg-intel dmg-universal test clean

build:
	CONFIG=$(CONFIG) ./scripts/build-app.sh

run: build
	open "$(APP)"

test:
	./scripts/build-app.sh test

dmg: dmg-silicon dmg-intel dmg-universal

dmg-silicon:
	$(MAKE) package ARCHS=arm64 FLAVOR=apple-silicon

dmg-intel:
	$(MAKE) package ARCHS=x86_64 FLAVOR=intel

dmg-universal:
	$(MAKE) package ARCHS="arm64 x86_64" FLAVOR=universal

# The app beside a link to Applications, to drag it across. Called by the
# dmg-* targets with ARCHS and FLAVOR.
package:
	CONFIG=Release ARCHS="$(ARCHS)" ./scripts/build-app.sh
	rm -rf dist/.stage
	mkdir -p dist/.stage
	ditto "$(RELEASE)" "$(STAGE)/NIMQO.app"
	ln -s /Applications "$(STAGE)/Applications"
	@version=$$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$(RELEASE)/Contents/Info.plist"); \
	name="dist/NIMQO-$$version-$(FLAVOR).dmg"; \
	rm -f "$$name"; \
	hdiutil create -quiet -volname "NIMQO $$version" -srcfolder "$(STAGE)" \
		-fs HFS+ -format UDZO "$$name" && \
	echo "dmg ready: $$name ($$(lipo -archs "$(STAGE)/NIMQO.app/Contents/MacOS/NIMQO"))"
	rm -rf dist/.stage

clean:
	rm -rf app/build app/Generated dist
