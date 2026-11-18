.PHONY: all build run clean

all: build

build:
	chmod +x build.sh
	./build.sh --no-open

run:
	chmod +x build.sh
	./build.sh

clean:
	rm -rf build Nimbscape.app
