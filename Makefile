.PHONY: build test app run install clean

build:
	swift build

# CLT-only toolchain: Swift Testing framework lives outside the default
# search path (and XCTest is absent entirely — tests use Swift Testing).
TESTING_FW := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
ifneq ($(wildcard $(TESTING_FW)/Testing.framework),)
SWIFT_TEST_FLAGS := -Xswiftc -F$(TESTING_FW) \
	-Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
	-Xlinker -F$(TESTING_FW) -Xlinker -rpath -Xlinker $(TESTING_FW)
endif

# -disable-cross-import-overlays lets test files import Foundation alongside
# Testing (the _Testing_Foundation overlay module is not resolvable under CLT).
test:
	swift test $(SWIFT_TEST_FLAGS)
	python3 -m unittest discover -s Tests/DaemonTests -p 'test_*.py'

app:
	bash scripts/build-app.sh release

run: app
	open dist/sr.app

# Install to /Applications. The Accessibility grant follows the signing
# identity (bundle id + sr-dev cert), not the path, so it survives this.
install: app
	pkill -f 'sr.app/Contents/MacOS/sr' 2>/dev/null || true
	rm -rf /Applications/sr.app
	cp -R dist/sr.app /Applications/sr.app
	open /Applications/sr.app

clean:
	rm -rf .build dist
