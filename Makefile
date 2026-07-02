.PHONY: build ipa clean help

PROJECT       = iCTRL.xcodeproj
SCHEME        = iCTRL
DERIVED_DATA  = build
BUILD_DIR     = $(DERIVED_DATA)/Build/Products/Debug-iphoneos

MAIN_APP      = iCTRL.app
MAIN_IPA      = iCTRL.ipa

RUNNER_APP    = iCTRLUITests-Runner.app
XCTEST_BUNDLE = iCTRLUITests.xctest
RUNNER_IPA    = iCTRLUITests-Runner.ipa

# Auto-detect signing identity
SIGN_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | head -1 | sed 's/.*"\(.*\)"/\1/')

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
	@echo "🔗 Registering ictrl:// URL scheme..."
	@PLIST="$(BUILD_DIR)/$(RUNNER_APP)/Info.plist"; \
	/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$$PLIST" 2>/dev/null || true; \
	/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0 dict" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLName string com.openminis.ictrl" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string ictrl" "$$PLIST"
	@echo "🔏 Re-signing Runner..."
	codesign --force --sign "$(SIGN_IDENTITY)" \
		"$(BUILD_DIR)/$(RUNNER_APP)/PlugIns/$(XCTEST_BUNDLE)"
	codesign --force --sign "$(SIGN_IDENTITY)" --preserve-metadata=entitlements \
		"$(BUILD_DIR)/$(RUNNER_APP)"
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
