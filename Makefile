.PHONY: build app debug-app run test check test-integration test-all test-xcode test-tsan bench coverage install clean \
	l10n-sync l10n-check l10n-pseudo

# Xcode is required (the Command Line Tools alone can't build the app target). The Xcode chosen with
# `xcode-select -s` is used; only when that is the Command Line Tools does this fall back to
# /Applications/Xcode.app. Set DEVELOPER_DIR to pick another one.
ifeq ($(origin DEVELOPER_DIR),undefined)
  ifneq ($(findstring CommandLineTools,$(shell xcode-select -p 2>/dev/null)),)
    DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
    export DEVELOPER_DIR
  endif
endif

# A stable signing identity keeps macOS privacy grants across rebuilds (see Config/Local.xcconfig.example).
# Without a Config/Local.xcconfig, use DOWN_SIGN_IDENTITY, or "Down Local Signing" when it's in the keychain
# (scripts/make-dev-cert.sh). An explicit DOWN_SIGN_IDENTITY wins over Local.xcconfig. Empty: ad-hoc.
ifeq ($(origin DOWN_SIGN_IDENTITY),undefined)
  ifeq ($(wildcard Config/Local.xcconfig),)
    DOWN_SIGN_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null \
      | grep -q '"Down Local Signing"' && echo 'Down Local Signing')
  endif
endif
ifneq ($(DOWN_SIGN_IDENTITY),)
  # Same as option B in Config/Local.xcconfig.example.
  SIGNING := CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$(DOWN_SIGN_IDENTITY)" DEVELOPMENT_TEAM= \
    ENABLE_DEBUG_DYLIB=NO
endif

DERIVED_DATA := build/xcode
# Native architecture only, like the old scripts/bundle.sh: Release would otherwise build universal.
XCODEBUILD := xcodebuild -project Down.xcodeproj -scheme Down -derivedDataPath $(DERIVED_DATA) \
	-destination 'platform=macOS,arch=$(shell uname -m)' ONLY_ACTIVE_ARCH=YES $(SIGNING)

# Builds Down.app with Xcode and copies it to build/Down.app (used by run, install and scripts/down).
define build_app
	$(XCODEBUILD) -configuration $(1) build
	rm -rf build/Down.app
	ditto "$(DERIVED_DATA)/Build/Products/$(1)/Down.app" build/Down.app
	@echo "Built build/Down.app ($(1), signed with $(or $(DOWN_SIGN_IDENTITY),the Config/*.xcconfig identity))"
endef

build:
	$(XCODEBUILD) -configuration Debug build

app:
	$(call build_app,Release)

debug-app:
	$(call build_app,Debug)

# Runs in the foreground so stderr logs show up in this terminal.
run: debug-app
	./build/Down.app/Contents/MacOS/Down --log-level debug $(ARGS)

# Unit + ViewModel + in-process AppKit tests (fast).
test:
	swift test

# Run before opening a PR: the tests plus the String Catalog check.
check: test l10n-check

# Updates Sources/*/Localizable.xcstrings from the strings used in code (see README → Localization).
l10n-sync:
	scripts/l10n.sh sync

# Fails if the String Catalogs are out of date (new, unused or conflicting keys).
l10n-check:
	scripts/l10n.sh check

# Snapshots of the main and Settings windows in Xcode's accented and double-length pseudolanguages.
# Accented text went through a catalog; plain text is a literal that bypasses it. Double-length text
# shows truncation and clipping. Plural strings render garbled in both (a Foundation quirk with
# pseudolanguages, not a bug). Output: build/l10n/*.png
L10N_FIXTURE := build/l10n/fixture
l10n-pseudo: debug-app
	mkdir -p "$(L10N_FIXTURE)/Projects" "$(L10N_FIXTURE)/Holiday photos 2024"
	printf 'notes' > "$(L10N_FIXTURE)/notes.txt"
	printf '%04096d' 0 > "$(L10N_FIXTURE)/A rather long document name for the quarterly report.pdf"
	DOWN_SNAPSHOT_SETTINGS=1 ./build/Down.app/Contents/MacOS/Down -NSAccentuateLocalizedStrings YES \
	  --snapshot build/l10n/accented.png "$(L10N_FIXTURE)"
	DOWN_SNAPSHOT_SETTINGS=1 ./build/Down.app/Contents/MacOS/Down -NSDoubleLocalizedStrings YES \
	  --snapshot build/l10n/double.png "$(L10N_FIXTURE)"
	@ls build/l10n/*.png

# Real-filesystem tests (temp dirs, FSEvents, copyfile).
test-integration:
	DOWN_TEST_INTEGRATION=1 swift test

# Everything, including disk-image volume tests and snapshots.
test-all:
	DOWN_TEST_INTEGRATION=1 DOWN_TEST_VOLUMES=1 DOWN_TEST_SNAPSHOTS=1 swift test

# The same tests through the Xcode scheme. xcodebuild only forwards environment variables to the
# test runner with a TEST_RUNNER_ prefix, e.g. TEST_RUNNER_DOWN_TEST_INTEGRATION=1 make test-xcode.
test-xcode:
	$(XCODEBUILD) test

# Thread Sanitizer over the unit and integration tests.
test-tsan:
	DOWN_TEST_INTEGRATION=1 swift test --sanitize=thread

bench:
	DOWN_TEST_PERFORMANCE=1 swift test -c release --filter Performance

# With Xcode's toolchain SwiftPM builds one test bundle per test target (no DownPackageTests.xctest).
coverage:
	swift test --enable-code-coverage
	bin="$$(swift build --show-bin-path)"; \
	xcrun llvm-cov report "$$bin/DownCoreTests.xctest/Contents/MacOS/DownCoreTests" \
	  -object "$$bin/DownUITests.xctest/Contents/MacOS/DownUITests" \
	  -instr-profile "$$bin/codecov/default.profdata" \
	  -ignore-filename-regex '(\.build|Tests|DownTestSupport)/'

install: app
	mkdir -p "$(HOME)/Applications"
	rm -rf "$(HOME)/Applications/Down.app"
	cp -R build/Down.app "$(HOME)/Applications/Down.app"
	mkdir -p "$(HOME)/.local/bin"
	install -m 755 scripts/down "$(HOME)/.local/bin/down"
	@echo "Installed ~/Applications/Down.app and ~/.local/bin/down"

clean:
	rm -rf .build build
