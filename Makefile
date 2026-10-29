APP_NAME ?= FreeFlow Dev
BUNDLE_ID ?= com.zachlatta.freeflow.dev
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CODESIGN_IDENTITY ?= FreeFlow Dev
CONTENTS = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS)/MacOS
empty :=
space := $(empty) $(empty)
APP_EXECUTABLE = $(MACOS_DIR)/$(APP_NAME)
APP_EXECUTABLE_TARGET := $(subst $(space),\ ,$(APP_EXECUTABLE))

SOURCES = $(shell find Sources -name '*.swift' -type f | LC_ALL=C sort)
TEST_RUNNER = $(BUILD_DIR)/FreeFlowTests
TEST_DISPATCH_HARNESS = $(BUILD_DIR)/AppTextInsertionDispatchHarness.swift
TEST_PRODUCTION_SOURCES = \
	Sources/APIConfigurationDraft.swift \
	Sources/AlertSoundPreference.swift \
	Sources/VocabularyPrompt.swift \
	Sources/AppContextService.swift \
	Sources/AppName.swift \
	Sources/AppStyle.swift \
	Sources/CleanupLevel.swift \
	Sources/AppTextInsertionCore.swift \
	Sources/AppTextInsertionTarget.swift \
	Sources/ContextInferenceFailure.swift \
	Sources/LLMAPITransport.swift \
	Sources/LLMCooldownManager.swift \
	Sources/MicrophoneReadinessPreference.swift \
	Sources/ModelConfiguration.swift \
	Sources/OriginalFieldInsertionPreference.swift \
	Sources/PostProcessingService.swift \
	Sources/OverlayPlacementPreference.swift \
	Sources/RecordingCaptureTiming.swift \
	Sources/RecordingTimerPreference.swift \
	Sources/TranscriptionErrorPresentationCore.swift \
	Sources/TranscriptTextCore.swift \
	Sources/TemperatureCapabilityCache.swift \
	Sources/TranscriptionService.swift \
	Sources/UpdateManager.swift \
	Sources/ShortcutCore/DictationShortcutSessionController.swift \
	Sources/ShortcutCore/ShortcutMatcher.swift \
	Sources/ShortcutCore/ShortcutModels.swift
TEST_SOURCES = $(shell find Tests -name '*.swift' -type f | LC_ALL=C sort)
SHELL_SCRIPTS = $(shell find .github/scripts .agents/skills -name '*.sh' -type f | LC_ALL=C sort)
YAML_FILES = $(shell find .github -type f \( -name '*.yml' -o -name '*.yaml' \) | LC_ALL=C sort)
RESOURCES = $(CONTENTS)/Resources
SOUND_RESOURCES = $(shell find Resources/Sounds -name '*.wav' -type f | LC_ALL=C sort)
ARCH ?= $(shell uname -m)

# Pick the icon source based on which bundle we are building. Dev builds get
# a distinct hammer-on-waveform icon so a developer's dock shows at a glance
# which FreeFlow they are running when both are installed side by side.
ifeq ($(APP_NAME),FreeFlow Dev)
ICON_SOURCE = Resources/AppIcon-Dev-Source.png
ICON_ICNS = Resources/AppIcon-Dev.icns
else
ICON_SOURCE = Resources/AppIcon-Source.png
ICON_ICNS = Resources/AppIcon.icns
endif

.PHONY: all check clean run icon dmg codesign-dmg notarize test typecheck validate install-local install

all: $(APP_EXECUTABLE_TARGET)

$(APP_EXECUTABLE_TARGET): $(SOURCES) Info.plist $(ICON_ICNS) $(SOUND_RESOURCES)
	@mkdir -p "$(MACOS_DIR)" "$(RESOURCES)"
ifeq ($(ARCH),universal)
	swiftc \
		-parse-as-library \
		-o "$(MACOS_DIR)/$(APP_NAME)-arm64" \
		-sdk $(shell xcrun --show-sdk-path) \
		-target arm64-apple-macosx13.0 \
		$(SOURCES)
	swiftc \
		-parse-as-library \
		-o "$(MACOS_DIR)/$(APP_NAME)-x86_64" \
		-sdk $(shell xcrun --show-sdk-path) \
		-target x86_64-apple-macosx13.0 \
		$(SOURCES)
	lipo -create -output "$(MACOS_DIR)/$(APP_NAME)" \
		"$(MACOS_DIR)/$(APP_NAME)-arm64" \
		"$(MACOS_DIR)/$(APP_NAME)-x86_64"
	@rm "$(MACOS_DIR)/$(APP_NAME)-arm64" "$(MACOS_DIR)/$(APP_NAME)-x86_64"
else
	swiftc \
		-parse-as-library \
		-o "$(MACOS_DIR)/$(APP_NAME)" \
		-sdk $(shell xcrun --show-sdk-path) \
		-target $(ARCH)-apple-macosx13.0 \
		$(SOURCES)
endif
	@cp Info.plist "$(CONTENTS)/"
	@plutil -replace CFBundleName -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleDisplayName -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleExecutable -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleIdentifier -string "$(BUNDLE_ID)" "$(CONTENTS)/Info.plist"
	@cp $(ICON_ICNS) "$(RESOURCES)/AppIcon.icns"
	@cp $(SOUND_RESOURCES) "$(RESOURCES)/"
	@plutil -replace NSMicrophoneUsageDescription -string "$(APP_NAME) needs microphone access to transcribe your speech." "$(CONTENTS)/Info.plist"
	@plutil -replace NSSpeechRecognitionUsageDescription -string "$(APP_NAME) needs speech recognition to convert your voice to text." "$(CONTENTS)/Info.plist"
	@plutil -replace NSAccessibilityUsageDescription -string "$(APP_NAME) needs accessibility access to detect the text cursor position and paste transcribed text." "$(CONTENTS)/Info.plist"
	@codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" --entitlements FreeFlow.entitlements "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE)"

check: typecheck test validate

typecheck:
	swiftc \
		-parse-as-library \
		-typecheck \
		-warnings-as-errors \
		-sdk $(shell xcrun --show-sdk-path) \
		-target $(ARCH)-apple-macosx13.0 \
		$(SOURCES)

$(TEST_DISPATCH_HARNESS): Sources/AppState.swift Tests/generate-insertion-dispatch-harness.rb
	@mkdir -p "$(BUILD_DIR)"
	ruby Tests/generate-insertion-dispatch-harness.rb $< "$@"

test: $(TEST_DISPATCH_HARNESS)
	@mkdir -p "$(BUILD_DIR)"
	swiftc \
		-parse-as-library \
		-warnings-as-errors \
		-o "$(TEST_RUNNER)" \
		-sdk $(shell xcrun --show-sdk-path) \
		-target $(ARCH)-apple-macosx13.0 \
		$(TEST_PRODUCTION_SOURCES) \
		$(TEST_SOURCES) \
		"$(TEST_DISPATCH_HARNESS)"
	@$(TEST_RUNNER)

validate:
	plutil -lint Info.plist FreeFlow.entitlements
	@set -e; for script in $(SHELL_SCRIPTS); do bash -n "$$script"; done
	@ruby -e 'require "yaml"; ARGV.each { |file| YAML.load_file(file) }' $(YAML_FILES)

icon: $(ICON_ICNS)

$(ICON_ICNS): $(ICON_SOURCE)
	@mkdir -p $(BUILD_DIR)/AppIcon.iconset
	@sips -z 16 16 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_16x16.png > /dev/null
	@sips -z 32 32 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_16x16@2x.png > /dev/null
	@sips -z 32 32 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_32x32.png > /dev/null
	@sips -z 64 64 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_32x32@2x.png > /dev/null
	@sips -z 128 128 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_128x128.png > /dev/null
	@sips -z 256 256 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_128x128@2x.png > /dev/null
	@sips -z 256 256 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_256x256.png > /dev/null
	@sips -z 512 512 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_256x256@2x.png > /dev/null
	@sips -z 512 512 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_512x512.png > /dev/null
	@sips -z 1024 1024 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_512x512@2x.png > /dev/null
	@iconutil -c icns -o $@ $(BUILD_DIR)/AppIcon.iconset
	@rm -rf $(BUILD_DIR)/AppIcon.iconset
	@echo "Generated $@"

dmg: all
	@rm -f "$(BUILD_DIR)/$(APP_NAME).dmg"
	@rm -rf $(BUILD_DIR)/dmg-staging
	@mkdir -p $(BUILD_DIR)/dmg-staging
	@cp -R "$(APP_BUNDLE)" $(BUILD_DIR)/dmg-staging/
	@osascript -e 'tell application "Finder" to make alias file to POSIX file "/Applications" at POSIX file "'"$$(cd $(BUILD_DIR)/dmg-staging && pwd)"'"'
	@ALIAS=$$(find $(BUILD_DIR)/dmg-staging -maxdepth 1 -not -name '*.app' -not -name '.DS_Store' -type f | head -1) && mv "$$ALIAS" "$(BUILD_DIR)/dmg-staging/Applications"
	@fileicon set "$(BUILD_DIR)/dmg-staging/Applications" /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns
	@echo "Creating DMG..."
	@create-dmg \
		--volname "$(APP_NAME)" \
		--volicon "$(ICON_ICNS)" \
		--background "Resources/dmg-background.tiff" \
		--window-pos 200 120 \
		--window-size 660 400 \
		--icon-size 128 \
		--icon "$(APP_NAME).app" 180 170 \
		--hide-extension "$(APP_NAME).app" \
		--icon "Applications" 480 170 \
		--no-internet-enable \
		"$(BUILD_DIR)/$(APP_NAME).dmg" \
		"$(BUILD_DIR)/dmg-staging"
	@rm -rf $(BUILD_DIR)/dmg-staging
	@echo "Created $(BUILD_DIR)/$(APP_NAME).dmg"

codesign-dmg: dmg
	codesign --force --sign "$(CODESIGN_IDENTITY)" "$(BUILD_DIR)/$(APP_NAME).dmg"

notarize:
	xcrun notarytool submit "$(BUILD_DIR)/$(APP_NAME).dmg" \
		--keychain-profile "$(NOTARIZE_PROFILE)" --wait
	xcrun stapler staple "$(BUILD_DIR)/$(APP_NAME).dmg"

clean:
	rm -rf $(BUILD_DIR)

run: all
	open "$(APP_BUNDLE)"

# Personal build that replaces the installed FreeFlow.app in place. It keeps the
# production name and bundle ID so existing settings carry over, stamps the
# latest release version so the updater doesn't offer the same release, and
# leaves no second copy in build/ for macOS permissions to confuse with it.
LOCAL_INSTALL_APP = /Applications/FreeFlow.app
LOCAL_IDENTITY ?= $(shell security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)
LOCAL_VERSION ?= $(shell git describe --tags --abbrev=0 | sed 's/^v//')

install-local:
	@test -n "$(LOCAL_IDENTITY)" || { echo "No Apple Development signing identity found"; exit 1; }
	@rm -rf "$(BUILD_DIR)/FreeFlow.app"
	$(MAKE) all APP_NAME=FreeFlow BUNDLE_ID=com.zachlatta.freeflow CODESIGN_IDENTITY="$(LOCAL_IDENTITY)"
	@plutil -replace CFBundleShortVersionString -string "$(LOCAL_VERSION)" "$(BUILD_DIR)/FreeFlow.app/Contents/Info.plist"
	@codesign --force --options runtime --sign "$(LOCAL_IDENTITY)" --entitlements FreeFlow.entitlements "$(BUILD_DIR)/FreeFlow.app"
	@osascript -e 'quit app "FreeFlow"' >/dev/null 2>&1 || true
	@while pgrep -x FreeFlow >/dev/null; do sleep 0.5; done
	@rm -rf "$(LOCAL_INSTALL_APP)"
	@mv "$(BUILD_DIR)/FreeFlow.app" "$(LOCAL_INSTALL_APP)"
	@echo "Installed $(LOCAL_INSTALL_APP) ($(LOCAL_VERSION), signed by $(LOCAL_IDENTITY))"

# Installs the latest origin/main rather than the working tree, so uncommitted
# or unpushed work never ends up in /Applications. The build runs in a
# throwaway worktree and leaves the current checkout untouched.
INSTALL_WORKTREE = $(CURDIR)/$(BUILD_DIR)/install-main

install:
	git fetch --quiet origin main
	@git worktree remove --force "$(INSTALL_WORKTREE)" >/dev/null 2>&1 || rm -rf "$(INSTALL_WORKTREE)"
	@git worktree prune
	@git worktree add --detach --quiet "$(INSTALL_WORKTREE)" origin/main
	@echo "Building origin/main at $$(git -C "$(INSTALL_WORKTREE)" log -1 --format='%h %s')"
	@status=0; $(MAKE) --no-print-directory -C "$(INSTALL_WORKTREE)" install-local || status=$$?; \
		git worktree remove --force "$(INSTALL_WORKTREE)"; \
		test $$status -eq 0 && open "$(LOCAL_INSTALL_APP)"; \
		exit $$status
