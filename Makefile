SHELL := /bin/sh
CLANG := xcrun --sdk macosx clang
BUILD := build
DIST := dist

.PHONY: all clean release test

all: $(BUILD)/ptywrap $(BUILD)/httpd

$(BUILD):
	mkdir -p $@

$(DIST):
	mkdir -p $@

$(BUILD)/ptywrap.arm64: src/ptywrap.c | $(BUILD)
	$(CLANG) -Os -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=11.0 $< -o $@

$(BUILD)/ptywrap.x86_64: src/ptywrap.c | $(BUILD)
	$(CLANG) -Os -Wall -Wextra -Werror -arch x86_64 -mmacosx-version-min=10.13 $< -o $@

$(BUILD)/ptywrap: $(BUILD)/ptywrap.arm64 $(BUILD)/ptywrap.x86_64
	lipo -create $^ -output $@
	codesign --force --sign - $@

$(BUILD)/httpd.arm64: src/httpd.c | $(BUILD)
	$(CLANG) -Os -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=11.0 $< -o $@

$(BUILD)/httpd.x86_64: src/httpd.c | $(BUILD)
	$(CLANG) -Os -Wall -Wextra -Werror -arch x86_64 -mmacosx-version-min=10.13 $< -o $@

$(BUILD)/httpd: $(BUILD)/httpd.arm64 $(BUILD)/httpd.x86_64
	lipo -create $^ -output $@
	codesign --force --sign - $@

release: all | $(DIST)
	cp $(BUILD)/ptywrap $(DIST)/ptywrap
	cp $(BUILD)/httpd $(DIST)/httpd
	cd $(DIST) && shasum -a 256 ptywrap httpd > SHA256SUMS

test: release
	sh tests/test.sh

clean:
	rm -rf $(BUILD) $(DIST)/ptywrap $(DIST)/httpd $(DIST)/SHA256SUMS
