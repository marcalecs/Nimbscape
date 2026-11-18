.PHONY: all build run clean

all: build

build:
	chmod +x build.sh
	./build.sh

run: build
	open Nimbscape.app

clean:
	rm -rf build Nimbscape.app
