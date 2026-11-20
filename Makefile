.PHONY: all build run dmg clean test

all: build

build:
	chmod +x build.sh
	./build.sh --no-open

run:
	chmod +x build.sh
	./build.sh

dmg: build
	chmod +x create_dmg.sh
	./create_dmg.sh

clean:
	rm -rf build Nimbscape.app Nimbscape.dmg

test:
	mkdir -p build
	swiftc -swift-version 6 -target "$$(uname -m)-apple-macosx14.0" Sources/Core/*.swift Tests/*.swift -o build/NimbscapeTests
	./build/NimbscapeTests
