.PHONY: build ipa clean help

PROJECT       = iCTRL.xcodeproj
SCHEME        = iCTRL
DERIVED_DATA  = build
BUILD_DIR     = $(DERIVED_DATA)/Build/Products/Debug-iphoneos

MAIN_APP      = iCTRL.app
MAIN_IPA      = iCTRL.ipa

RUNNER_APP    = iCTRLUITests-Runner.app
RUNNER_BIN    = iCTRLUITests-Runner
XCTEST_BUNDLE = iCTRLUITests.xctest
RUNNER_IPA    = iCTRLUITests-Runner.ipa

# Signing identity is read from the freshly-built app (below, in `ipa`) so the
# re-sign uses EXACTLY what xcodebuild chose from the Xcode project's automatic
# signing — never a guessed keychain identity. Do NOT hardcode it here.

# ──────────────────────────────────────────────
# Build both targets with Xcode signing
# ──────────────────────────────────────────────
build: Frameworks/IDevice.xcframework
build:
	xcodebuild build-for-testing \
		-project $(PROJECT) \
		-derivedDataPath $(DERIVED_DATA) \
		-scheme $(SCHEME) \
		-destination "generic/platform=iOS" \
		-allowProvisioningUpdates \
		ARCHS=arm64
	@echo ""
	@echo "✅ Build completed"
	@echo "   $(BUILD_DIR)/$(MAIN_APP)"
	@echo "   $(BUILD_DIR)/$(RUNNER_APP)"

# ──────────────────────────────────────────────
# Package both IPAs
#
#   iCTRL.ipa                — Main app (settings & control UI)
#   iCTRLUITests-Runner.ipa  — XCTest runner (automation engine)
# ──────────────────────────────────────────────
ipa: build
	@echo ""
	@# The runner is packaged FIRST so the app can carry a copy of it: the app's
	@# installer offers the bundled runner as its default package, which means
	@# the .ipa has to exist before the app is zipped. Both come out of the same
	@# xcodebuild invocation, so this is purely an ordering constraint.
	@# === Runner IPA ===
	@echo "🎨 Copying app icon to Runner..."
	@# Copy main app's icon assets into Runner so it shows the same icon
	@if [ -d "$(BUILD_DIR)/$(MAIN_APP)/Assets.car" ]; then \
		cp "$(BUILD_DIR)/$(MAIN_APP)/Assets.car" "$(BUILD_DIR)/$(RUNNER_APP)/Assets.car"; \
	fi
	@# Also copy the AppIcon directly for iOS to pick up
	@for f in $(BUILD_DIR)/$(MAIN_APP)/AppIcon*.png; do \
		[ -f "$$f" ] && cp "$$f" "$(BUILD_DIR)/$(RUNNER_APP)/" || true; \
	done
	@echo "🔧 Stripping XCTest frameworks from Runner..."
	rm -rf "$(BUILD_DIR)/$(RUNNER_APP)/Frameworks/XCTAutomationSupport.framework"
	rm -rf "$(BUILD_DIR)/$(RUNNER_APP)/Frameworks/XCTest.framework"
	rm -rf "$(BUILD_DIR)/$(RUNNER_APP)/Frameworks/XCTestCore.framework"
	rm -rf "$(BUILD_DIR)/$(RUNNER_APP)/Frameworks/XCTestSupport.framework"
	rm -rf "$(BUILD_DIR)/$(RUNNER_APP)/Frameworks/XCUIAutomation.framework"
	rm -rf "$(BUILD_DIR)/$(RUNNER_APP)/Frameworks/XCUnit.framework"
	rm -rf "$(BUILD_DIR)/$(RUNNER_APP)/Frameworks/Testing.framework"
	rm -f  "$(BUILD_DIR)/$(RUNNER_APP)/Frameworks/libXCTestSwiftSupport.dylib"
	@rmdir "$(BUILD_DIR)/$(RUNNER_APP)/Frameworks" 2>/dev/null || true
	@# ── Back-compat shim for older iOS (see iCTRLCompat/XCTCompatShim.m) ──
	@# Xcode's prebuilt XCTRunner stub hard-binds classes that don't exist in the
	@# XCTest shipped by older Developer disk images, so the runner dies at launch
	@# with "Symbol not found: _OBJC_CLASS_$$_XCTCommandLineToolHelper" on e.g.
	@# iOS 16. We ship a dylib defining the missing class and re-point just that
	@# one bind record at it — the symbol is only touched on the --run-as-tool
	@# path, which testmanagerd-launched runs never take.
	@echo "🩹 Building + inserting the older-iOS compat shim..."
	@# Both steps below are one-shot: optool would add a second load command,
	@# and the bind record is already re-pointed, so retarget-bind-ordinal.py
	@# finds nothing to change and fails the build. That happens whenever `make
	@# ipa` runs twice without the runner being rebuilt in between, which reads
	@# as a broken build rather than as work already done.
	@set -e; \
	APP="$(BUILD_DIR)/$(RUNNER_APP)"; \
	if otool -L "$$APP/$(RUNNER_BIN)" | grep -q libXCTCompatShim; then \
		echo "   ✅ shim already present — skipping"; \
		exit 0; \
	fi; \
	SDK="$$(xcrun --sdk iphoneos --show-sdk-path)"; \
	mkdir -p "$$APP/Frameworks"; \
	xcrun -sdk iphoneos clang -dynamiclib -arch arm64 -isysroot "$$SDK" \
		-mios-version-min=16.0 -install_name "@rpath/libXCTCompatShim.dylib" \
		-framework Foundation -o "$$APP/Frameworks/libXCTCompatShim.dylib" \
		iCTRLCompat/XCTCompatShim.m; \
	optool install -c load -p "@rpath/libXCTCompatShim.dylib" \
		-t "$$APP/$(RUNNER_BIN)" >/dev/null; \
	ORD="$$(python3 Scripts/dylib-ordinal.py "$$APP/$(RUNNER_BIN)" libXCTCompatShim)"; \
	python3 Scripts/retarget-bind-ordinal.py "$$APP/$(RUNNER_BIN)" \
		'_OBJC_CLASS_$$_XCTCommandLineToolHelper' "$$ORD"; \
	python3 Scripts/retarget-undef-symbol.py "$$APP/$(RUNNER_BIN)" \
		'_OBJC_CLASS_$$_XCTCommandLineToolHelper' libXCTCompatShim
	@echo "🧹 Removing dSYM debug symbols from the app..."
	@# build-for-testing embeds a .dSYM inside the app; it is debug-symbol data,
	@# not needed at runtime, and bloats the IPA (~3MB). Strip it before packaging.
	@find "$(BUILD_DIR)/$(RUNNER_APP)" -name "*.dSYM" -exec rm -rf {} + 2>/dev/null || true
	@echo "🔗 Registering ictrl:// URL scheme..."
	@PLIST="$(BUILD_DIR)/$(RUNNER_APP)/Info.plist"; \
	/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$$PLIST" 2>/dev/null || true; \
	/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0 dict" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLName string com.openminis.ictrl" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string ictrl" "$$PLIST"
	@echo "🏷  Aligning .xctest bundle id with the Runner..."
	@# Rewrite the embedded .xctest CFBundleIdentifier to match the Runner app id,
	@# so the plugin and its host share one identifier. Done BEFORE the re-sign so
	@# the new plist is covered by the signature. Runner id is read at runtime
	@# (not hardcoded).
	@set -e; \
	RUNNER_PLIST="$(BUILD_DIR)/$(RUNNER_APP)/Info.plist"; \
	XCTEST_PLIST="$(BUILD_DIR)/$(RUNNER_APP)/PlugIns/$(XCTEST_BUNDLE)/Info.plist"; \
	RUNNER_ID="$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$$RUNNER_PLIST")"; \
	OLD_ID="$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$$XCTEST_PLIST")"; \
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $$RUNNER_ID" "$$XCTEST_PLIST"; \
	echo "   .xctest: $$OLD_ID -> $$RUNNER_ID"
	@echo "🔏 Re-signing Runner (identity read back from what xcodebuild signed)..."
	@# Read the signing identity xcodebuild actually used, straight off the built
	@# app — this reflects the Xcode project's automatic signing (team + cert),
	@# so the re-sign can never drift from the build. Match by the cert's SHA-1 in
	@# the keychain to pin the exact identity.
	@set -e; \
	APP="$(BUILD_DIR)/$(RUNNER_APP)"; \
	AUTH="$$(codesign -dvv "$$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"; \
	if [ -z "$$AUTH" ]; then echo "🔴 could not read signing identity from $$APP"; exit 1; fi; \
	SHA="$$(security find-identity -v -p codesigning 2>/dev/null | grep -F "$$AUTH" | head -1 | awk '{print $$2}')"; \
	IDENT="$${SHA:-$$AUTH}"; \
	echo "   using: $$AUTH ($$IDENT)"; \
	for dylib in "$$APP/Frameworks/"*.dylib; do \
		[ -f "$$dylib" ] || continue; \
		echo "   signing $$(basename "$$dylib")"; \
		codesign --force --sign "$$IDENT" "$$dylib"; \
	done; \
	codesign --force --sign "$$IDENT" "$$APP/PlugIns/$(XCTEST_BUNDLE)"; \
	codesign --force --sign "$$IDENT" --preserve-metadata=entitlements "$$APP"
	@# Everything dyld loads must carry a signature — an unsigned dylib in
	@# Frameworks/ makes the runner die at launch with "mapped file has no
	@# cdhash", which looks nothing like a signing problem from the device side.
	@echo "🔍 Verifying every embedded binary is signed..."
	@set -e; \
	APP="$(BUILD_DIR)/$(RUNNER_APP)"; \
	for f in "$$APP/Frameworks/"*.dylib "$$APP/PlugIns/$(XCTEST_BUNDLE)" "$$APP"; do \
		[ -e "$$f" ] || continue; \
		codesign -v "$$f" 2>/dev/null || { echo "🔴 unsigned: $$f"; exit 1; }; \
	done; \
	echo "   ✅ all embedded binaries signed"
	@echo "📦 Packaging $(RUNNER_IPA)..."
	rm -rf "$(BUILD_DIR)/Payload"
	mkdir -p "$(BUILD_DIR)/Payload"
	cp -R "$(BUILD_DIR)/$(RUNNER_APP)" "$(BUILD_DIR)/Payload/"
	cd "$(BUILD_DIR)" && zip -qr "$(RUNNER_IPA)" Payload/
	mv "$(BUILD_DIR)/$(RUNNER_IPA)" ./
	rm -rf "$(BUILD_DIR)/Payload"
	@echo "✅ $(RUNNER_IPA)"
	@echo ""
	@# === Main App IPA (carrying the runner just built) ===
	@# Copied in after the app is built rather than declared as a project
	@# resource: the runner doesn't exist until the step above, so XcodeGen has
	@# nothing to reference at generate time.
	@echo "🎁 Embedding $(RUNNER_IPA) into the app..."
	@cp "$(RUNNER_IPA)" "$(BUILD_DIR)/$(MAIN_APP)/$(RUNNER_IPA)"
	@ls -lh "$(BUILD_DIR)/$(MAIN_APP)/$(RUNNER_IPA)" | awk '{print "   " $$5 "  " $$9}'
	@# Re-sign: adding a file to a signed bundle invalidates its signature, and
	@# an app whose seal is broken is rejected at install.
	@set -e; \
	APP="$(BUILD_DIR)/$(MAIN_APP)"; \
	AUTH="$$(codesign -dvv "$$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"; \
	if [ -z "$$AUTH" ]; then echo "🔴 could not read signing identity from $$APP"; exit 1; fi; \
	SHA="$$(security find-identity -v -p codesigning 2>/dev/null | grep -F "$$AUTH" | head -1 | awk '{print $$2}')"; \
	codesign --force --sign "$${SHA:-$$AUTH}" --preserve-metadata=entitlements "$$APP"; \
	codesign -v "$$APP" || { echo "🔴 re-sign failed"; exit 1; }; \
	echo "   ✅ app re-signed"
	@echo "📦 Packaging $(MAIN_IPA)..."
	rm -rf "$(BUILD_DIR)/Payload"
	mkdir -p "$(BUILD_DIR)/Payload"
	cp -R "$(BUILD_DIR)/$(MAIN_APP)" "$(BUILD_DIR)/Payload/"
	cd "$(BUILD_DIR)" && zip -qr "$(MAIN_IPA)" Payload/
	mv "$(BUILD_DIR)/$(MAIN_IPA)" ./
	rm -rf "$(BUILD_DIR)/Payload"
	@echo "✅ $(MAIN_IPA)"
	@ls -lh $(MAIN_IPA)
	@ls -lh $(RUNNER_IPA)
	@echo ""
	@echo "════════════════════════════════════════"
	@echo "  $(MAIN_IPA)  — Settings & control UI"
	@echo "  $(RUNNER_IPA)  — XCTest automation engine"
	@echo "════════════════════════════════════════"

# ──────────────────────────────────────────────
clean:
	rm -rf $(DERIVED_DATA)
	rm -f $(MAIN_IPA) $(RUNNER_IPA)
	@echo "✅ Cleaned"

help:
	@echo "iCTRL Build System"
	@echo ""
	@echo "  make build   Build both apps with Xcode signing"
	@echo "  make ipa     Build + package both IPAs"
	@echo "  make clean   Remove build artifacts"

# The idevice xcframework is a 215MB release asset, not vendored (see
# Scripts/fetch-idevice.sh). Fetch it on demand so a fresh clone builds.
Frameworks/IDevice.xcframework:
	@bash Scripts/fetch-idevice.sh
