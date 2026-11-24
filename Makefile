PREFIX ?= /usr/local
SWIFT_FLAGS ?=

.PHONY: all build agent install uninstall test e2e clean

all: build

build: agent
	swift build -c release $(SWIFT_FLAGS)

agent:
	scripts/build-agent.sh .build/agent

install: build
	install -d "$(PREFIX)/bin" "$(PREFIX)/lib/swapify" "$(PREFIX)/share/swapify"
	install -m 755 .build/release/swapify "$(PREFIX)/bin/swapify"
	install -m 644 .build/agent/SwapifyAgent.dylib "$(PREFIX)/lib/swapify/SwapifyAgent.dylib"
	install -m 644 .build/agent/SwapifyAgent-iphoneos.dylib "$(PREFIX)/lib/swapify/SwapifyAgent-iphoneos.dylib"
	install -m 644 skills/swapify/SKILL.md "$(PREFIX)/share/swapify/SKILL.md"

uninstall:
	rm -f "$(PREFIX)/bin/swapify"
	rm -rf "$(PREFIX)/lib/swapify" "$(PREFIX)/share/swapify"

test:
	swift test

e2e: agent
	swift build
	python3 -I scripts/e2e.py

clean:
	rm -rf .build
