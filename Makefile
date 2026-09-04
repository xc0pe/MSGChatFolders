# ══════════════════════════════════════════════════════════
# MSGChatFolders — Makefile
#
# Builds the tweak dylib for arm64 iOS.
# Designed to work with:
#   1. GitHub Actions (macOS runner + Xcode SDK)
#   2. Local macOS with Xcode command line tools
#   3. Zig cross-compiler on Windows/Linux
# ══════════════════════════════════════════════════════════

TWEAK_NAME     = MSGChatFolders
BUNDLE_ID      = com.facebook.Messenger
OUTPUT_DIR     = build
DYLIB_NAME     = $(TWEAK_NAME).dylib

# Source files
SOURCES = \
	MSGChatFolders_main.m \
	MSGChatFolderManager.m \
	MSGChatFolderTabView.m \
	MSGChatFolderHooks.m

# Compiler settings
ARCH           = arm64
MIN_IOS        = 15.0
SDK_PATH      ?= $(shell xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)

CC             = clang
CFLAGS         = -fobjc-arc \
                 -fmodules \
                 -target $(ARCH)-apple-ios$(MIN_IOS) \
                 -isysroot "$(SDK_PATH)" \
                 -Wall -Wno-unused-variable -Wno-unused-function \
                 -O2

LDFLAGS        = -dynamiclib \
                 -target $(ARCH)-apple-ios$(MIN_IOS) \
                 -isysroot "$(SDK_PATH)" \
                 -framework Foundation \
                 -framework UIKit \
                 -framework CoreGraphics \
                 -Wl,-undefined,dynamic_lookup \
                 -install_name @executable_path/Frameworks/$(DYLIB_NAME)

# ── Build targets ──

.PHONY: all clean

all: $(OUTPUT_DIR)/$(DYLIB_NAME)
	@echo ""
	@echo "═══════════════════════════════════════════════════"
	@echo " ✅ Build successful: $(OUTPUT_DIR)/$(DYLIB_NAME)"
	@echo "═══════════════════════════════════════════════════"
	@file $(OUTPUT_DIR)/$(DYLIB_NAME)

$(OUTPUT_DIR)/$(DYLIB_NAME): $(SOURCES)
	@mkdir -p $(OUTPUT_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SOURCES)

clean:
	rm -rf $(OUTPUT_DIR)

# ── Zig cross-compile (works on Windows/Linux without Xcode) ──

.PHONY: zig

zig:
	@mkdir -p $(OUTPUT_DIR)
	zig cc \
		-target aarch64-ios \
		-shared \
		-fobjc-arc \
		-Wl,-undefined,dynamic_lookup \
		-Wl,-install_name,@executable_path/Frameworks/$(DYLIB_NAME) \
		-framework Foundation \
		-framework UIKit \
		-framework CoreGraphics \
		-o $(OUTPUT_DIR)/$(DYLIB_NAME) \
		$(SOURCES)
	@echo ""
	@echo "═══════════════════════════════════════════════════"
	@echo " ✅ Zig build successful: $(OUTPUT_DIR)/$(DYLIB_NAME)"
	@echo "═══════════════════════════════════════════════════"
