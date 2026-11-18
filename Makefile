.PHONY: all build run dmg clean

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
