.PHONY: build test app run clean

build:
	swift build

test:
	swift test

app:
	bash scripts/build-app.sh release

run: app
	open dist/sr.app

clean:
	rm -rf .build dist
