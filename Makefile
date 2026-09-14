NAME = MSGChatFoldersDiagnostics
SDK := $(shell xcrun --sdk iphoneos --show-sdk-path)
CC := xcrun --sdk iphoneos clang

.PHONY: all clean
all: build/$(NAME).dylib

build/$(NAME).dylib: Diagnostics.m
	@mkdir -p build
	$(CC) -target arm64-apple-ios15.1 -isysroot "$(SDK)" -fobjc-arc -fblocks -fmodules -O2 -Wall -Wextra -Werror -Wno-unused-parameter -dynamiclib -framework Foundation -framework UIKit -install_name @executable_path/Frameworks/$(NAME).dylib Diagnostics.m -o $@
	codesign --force --sign - $@
	xcrun --sdk iphoneos lipo -verify_arch arm64 $@
	xcrun --sdk iphoneos otool -L $@
	codesign --verify $@
	shasum -a 256 $@ > build/SHA256SUMS.txt

clean:
	rm -rf build
