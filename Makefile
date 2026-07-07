.PHONY: build test app run clean

build:
	swift build

# CLT-only toolchain: Swift Testing framework lives outside the default
# search path (and XCTest is absent entirely — tests use Swift Testing).
TESTING_FW := /Library/Developer/CommandLineTools/Library/Developer/Frameworks

# -disable-cross-import-overlays lets test files import Foundation alongside
# Testing (the _Testing_Foundation overlay module is not resolvable under CLT).
test:
	swift test -Xswiftc -F$(TESTING_FW) \
		-Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
		-Xlinker -F$(TESTING_FW) -Xlinker -rpath -Xlinker $(TESTING_FW)

app:
	bash scripts/build-app.sh release

run: app
	open dist/sr.app

clean:
	rm -rf .build dist
