.PHONY: build app debug-app run test test-integration test-all bench coverage install clean

build:
	swift build

app:
	scripts/bundle.sh release

debug-app:
	scripts/bundle.sh debug

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

bench:
	DOWN_TEST_PERFORMANCE=1 swift test -c release --filter Performance

coverage:
	swift test --enable-code-coverage
	xcrun llvm-cov report "$$(swift build --show-bin-path)/DownPackageTests.xctest/Contents/MacOS/DownPackageTests" \
	  -instr-profile "$$(swift build --show-bin-path)/codecov/default.profdata" \
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
