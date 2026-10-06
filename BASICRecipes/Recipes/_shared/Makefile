# BASIC build. `basicc` comes from the BASICCompiler package in the
# BASICShell repo (`swift build` there puts it in .build/debug/basicc),
# or from its buildAndInstall.sh.
BASICC ?= basicc
BUILD := Build
NAME := {{NAME}}

.PHONY: run build clean help

## run — build, then run it
run: build
	$(BUILD)/$(NAME)

## build — compile src/main.bas to Build/$(NAME)
build:
	@mkdir -p $(BUILD)
	$(BASICC) build src/main.bas -o $(BUILD)/$(NAME)

## clean — remove everything the build produced
clean:
	rm -rf $(BUILD)

## help — list these targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## //'
