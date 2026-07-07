.PHONY: build ipa unsigned clean help

PROJECT       = iCTRL.xcodeproj
SCHEME        = iCTRL
DERIVED_DATA  = build
BUILD_DIR     = $(DERIVED_DATA)/Build/Products/Debug-iphoneos

MAIN_APP      = iCTRL.app
MAIN_IPA      = iCTRL.ipa

RUNNER_APP    = iCTRLUITests-Runner.app
XCTEST_BUNDLE = iCTRLUITests.xctest
RUNNER_IPA    = iCTRLUITests-Runner.ipa
UNSIGNED_IPA  = iCTRLUITests-Runner-unsigned.ipa

# Signing identity is read from the freshly-built app (below, in `ipa`) so the
# re-sign uses EXACTLY what xcodebuild chose from the Xcode project's automatic
# signing — never a guessed keychain identity. Do NOT hardcode it here.

# ──────────────────────────────────────────────
# Build both targets with Xcode signing
# ──────────────────────────────────────────────
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
	@# === Main App IPA ===
	@echo "📦 Packaging $(MAIN_IPA)..."
	rm -rf "$(BUILD_DIR)/Payload"
	mkdir -p "$(BUILD_DIR)/Payload"
	cp -R "$(BUILD_DIR)/$(MAIN_APP)" "$(BUILD_DIR)/Payload/"
	cd "$(BUILD_DIR)" && zip -qr "$(MAIN_IPA)" Payload/
	mv "$(BUILD_DIR)/$(MAIN_IPA)" ./
	rm -rf "$(BUILD_DIR)/Payload"
	@echo "✅ $(MAIN_IPA)"
	@ls -lh $(MAIN_IPA)
	@echo ""
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
	codesign --force --sign "$$IDENT" "$$APP/PlugIns/$(XCTEST_BUNDLE)"; \
	codesign --force --sign "$$IDENT" --preserve-metadata=entitlements "$$APP"
	@echo "📦 Packaging $(RUNNER_IPA)..."
	rm -rf "$(BUILD_DIR)/Payload"
	mkdir -p "$(BUILD_DIR)/Payload"
	cp -R "$(BUILD_DIR)/$(RUNNER_APP)" "$(BUILD_DIR)/Payload/"
	cd "$(BUILD_DIR)" && zip -qr "$(RUNNER_IPA)" Payload/
	mv "$(BUILD_DIR)/$(RUNNER_IPA)" ./
	rm -rf "$(BUILD_DIR)/Payload"
	@echo "✅ $(RUNNER_IPA)"
	@ls -lh $(RUNNER_IPA)
	@echo ""
	@echo "════════════════════════════════════════"
	@echo "  $(MAIN_IPA)  — Settings & control UI"
	@echo "  $(RUNNER_IPA)  — XCTest automation engine"
	@echo "════════════════════════════════════════"

# ──────────────────────────────────────────────
# Strip the code signature off the built Runner IPA.
#   Unzips $(RUNNER_IPA) into a temp dir under /tmp, removes the signature
#   from the .app and its embedded .xctest, then re-zips to $(UNSIGNED_IPA).
#   Requires `make ipa` first (uses its output as input).
# ──────────────────────────────────────────────
unsigned:
	@[ -f "$(RUNNER_IPA)" ] || { echo "🔴 $(RUNNER_IPA) not found — run 'make ipa' first"; exit 1; }
	@echo "🧊 Creating unsigned IPA from $(RUNNER_IPA)..."
	@set -e; \
	TMP="$$(mktemp -d /tmp/ictrl-unsigned.XXXXXX)"; \
	trap 'rm -rf "$$TMP"' EXIT; \
	unzip -qq "$(RUNNER_IPA)" -d "$$TMP"; \
	APP="$$TMP/Payload/$(RUNNER_APP)"; \
	[ -d "$$APP" ] || { echo "🔴 $(RUNNER_APP) not found inside IPA"; exit 1; }; \
	echo "   removing signatures..."; \
	find "$$APP" -name "_CodeSignature" -type d -exec rm -rf {} + 2>/dev/null || true; \
	codesign --remove-signature "$$APP/PlugIns/$(XCTEST_BUNDLE)" 2>/dev/null || true; \
	codesign --remove-signature "$$APP" 2>/dev/null || true; \
	rm -f "$$APP/embedded.mobileprovision"; \
	rm -f "$(UNSIGNED_IPA)"; \
	( cd "$$TMP" && zip -qr "$$OLDPWD/$(UNSIGNED_IPA)" Payload/ ); \
	echo "✅ $(UNSIGNED_IPA)"
	@ls -lh $(UNSIGNED_IPA)

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
	@echo "  make unsigned  Strip signature → iCTRLUITests-Runner-unsigned.ipa"
	@echo "  make clean   Remove build artifacts"
