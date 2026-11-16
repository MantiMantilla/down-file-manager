.PHONY: build app debug-app run test test-integration test-all test-xcode test-tsan bench coverage install clean

# Xcode is required (the Command Line Tools alone can't build the app target). Override to use another Xcode.
DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

DERIVED_DATA := build/xcode
XCODEBUILD := xcodebuild -project Down.xcodeproj -scheme Down -derivedDataPath $(DERIVED_DATA) \
	-destination 'platform=macOS,arch=$(shell uname -m)'

# Builds Down.app with Xcode and copies it to build/Down.app (used by run, install and scripts/down).
define build_app
	$(XCODEBUILD) -configuration $(1) build
	rm -rf build/Down.app
	ditto "$(DERIVED_DATA)/Build/Products/$(1)/Down.app" build/Down.app
	@echo "Built build/Down.app ($(1))"
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
	rm -rf .build build $(DERIVED_DATA)
