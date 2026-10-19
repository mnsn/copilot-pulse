.PHONY: build test app package install uninstall run dump watch render icon demo-data demo demo-check screenshots clean

# With only the Command Line Tools installed, the compiler sometimes misses Swift Testing's macro
# plugin (it lives in a subfolder), so point it there explicitly.
TESTING_PLUGINS := $(abspath $(dir $(shell xcrun --find swift))../lib/swift/host/plugins/testing)

# Made-up Copilot data with sessions in every state (see scripts/make-demo-data.swift).
DEMO_DIR := $(abspath build/demo)
DEMO_ENV := COPILOT_PULSE_COPILOT_DIR="$(DEMO_DIR)"
# The binary that demo-check runs: the debug build, unless scripts/check-app.sh passes a built app.
PULSE := .build/debug/CopilotPulse
SCREENSHOTS := menu-light menu-dark widget-large-light widget-large-dark

build:
	swift build

test:
	swift test $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS))

app:
	./scripts/build-app.sh

# The release zip: a universal app, checked and zipped, with its SHA-256 and notes in build/release.
package:
	./scripts/package.sh

install:
	./scripts/build-app.sh --install

uninstall:
	-pgrep -f "/Copilot Pulse.app/Contents/MacOS/CopilotPulse" | xargs kill 2>/dev/null
	rm -rf "$(HOME)/Applications/Copilot Pulse.app"

run: build
	.build/debug/CopilotPulse

dump: build
	.build/debug/CopilotPulse --dump

watch: build
	.build/debug/CopilotPulse --watch

render: build
	.build/debug/CopilotPulse --render build/render

demo-data:
	swift scripts/make-demo-data.swift "$(DEMO_DIR)"

# Runs the app with the demo data instead of your own sessions. Ctrl-C quits.
demo: build demo-data
	$(DEMO_ENV) .build/debug/CopilotPulse

# Checks that the engine sorts the demo sessions into the expected groups. CI runs this.
demo-check: $(if $(filter command line,$(origin PULSE)),,build) demo-data
	@counts=$$($(DEMO_ENV) "$(PULSE)" --json | jq -cS .counts); \
	expected='{"done":1,"idle":3,"needsYou":3,"running":2,"stopped":1}'; \
	if [ "$$counts" = "$$expected" ]; then echo "demo-check passed: $$counts"; \
	else echo "demo-check failed: expected $$expected, got $$counts" >&2; exit 1; fi

# Renders the README screenshots from the demo data.
screenshots: build demo-data
	$(DEMO_ENV) .build/debug/CopilotPulse --render build/screenshots
	mkdir -p docs/images
	for name in $(SCREENSHOTS); do cp build/screenshots/$$name.png docs/images/; done

icon:
	swift scripts/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

clean:
	rm -rf .build build
