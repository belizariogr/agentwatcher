.PHONY: build app install run test clean icon release

build:
	swift build

test:
	swift test

app:
	./scripts/build-app.sh

install: app
	pkill -x AgentWatcher || true
	rm -rf ~/Applications/AgentWatcher.app
	mkdir -p ~/Applications
	cp -R build/AgentWatcher.app ~/Applications/
	open ~/Applications/AgentWatcher.app

run: app
	pkill -x AgentWatcher || true
	open build/AgentWatcher.app

clean:
	rm -rf .build build

# make icon PALETTE=aurora BG=light  (options: scripts/app_icon.py --list)
icon:
	./scripts/make-icon.sh $(or $(PALETTE),ocean) $(or $(BG),black)

# Universal, Developer ID signed, notarized DMG in build/ (see scripts/release.sh)
release:
	./scripts/release.sh
