NAME = MSGChatFoldersPrototype
SDK := $(shell xcrun --sdk iphoneos --show-sdk-path)
CC := xcrun --sdk iphoneos clang

.PHONY: all clean test
all: build/$(NAME).dylib

build/$(NAME).dylib: Prototype.m Filter.h
	@mkdir -p build
	$(CC) -target arm64-apple-ios15.1 -isysroot "$(SDK)" -fobjc-arc -fblocks -fmodules -O2 -Wall -Wextra -Werror -Wno-unused-parameter -dynamiclib -framework Foundation -framework UIKit -install_name @executable_path/Frameworks/$(NAME).dylib Prototype.m -o $@
	codesign --force --sign - $@
	xcrun --sdk iphoneos lipo $@ -verify_arch arm64
	xcrun --sdk iphoneos otool -L $@
	codesign --verify $@
	shasum -a 256 $@ > build/SHA256SUMS.txt

clean:
	rm -rf build

test:
	@mkdir -p build
	xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror -framework Foundation FilterTests.m -o build/filter-tests
	./build/filter-tests
