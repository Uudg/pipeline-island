# Pipeline Island — build the .app bundle around the SPM binary.
# Staying on SPM (not an Xcode project) so contributors can `git clone && make`.

BINARY   := PipelineIsland
CONFIG   := debug
BUILDDIR := .build/$(CONFIG)
APP      := $(BUILDDIR)/$(BINARY).app
CONTENTS := $(APP)/Contents

.PHONY: all build app run clean verify verify-ui watch spikes

all: app

build:
	swift build -c $(CONFIG)

# Assemble a minimal LSUIElement app bundle around the built executable.
app: build
	@rm -rf "$(APP)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp "$(BUILDDIR)/$(BINARY)" "$(CONTENTS)/MacOS/$(BINARY)"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(CONTENTS)/Resources/AppIcon.icns"; fi
	@echo "APPL????" > "$(CONTENTS)/PkgInfo"
	@# Sign with the local self-signed identity when it exists, else ad-hoc.
	@# This matters for the Keychain: an ad-hoc signature's designated
	@# requirement is the binary's cdhash, which changes on EVERY rebuild, so
	@# macOS treats each build as a new app and re-prompts for the password.
	@# A certificate-based requirement is stable. See scripts/create-signing-identity.sh
	@if security find-certificate -c "Pipeline Island Dev" >/dev/null 2>&1; then \
		codesign --force --sign "Pipeline Island Dev" --identifier "com.pipelineisland.app" "$(APP)" 2>/dev/null \
			&& echo "  signed with 'Pipeline Island Dev' (stable identity)"; \
	else \
		codesign --force --sign - "$(APP)" 2>/dev/null \
			&& echo "  ad-hoc signed - run 'make signing-identity' to stop keychain prompts"; \
	fi
	@echo "built $(APP)"

run: app
	open "$(APP)"

# Scripted fake pipelines — no GitLab calls, no keychain, no real CI minutes.
# Loops: success run -> island exits -> failing run -> exits -> repeat.
demo: build
	@pkill -f PipelineIsland 2>/dev/null || true
	@"$(BUILDDIR)/$(BINARY)" --demo

# Demo with a SIMULATED MacBook notch (190x32pt), so the notched layout can be
# worked on with the laptop lid closed.
demo-notch: build
	@pkill -f PipelineIsland 2>/dev/null || true
	@"$(BUILDDIR)/$(BINARY)" --demo-notch

# Token/auth CLI commands. `watch` was the pre-UI harness and is now `run`.
verify: build
	@"$(BUILDDIR)/$(BINARY)" verify

# Stand the real panel up, print its measured frame, exit non-zero if no window
# with non-zero bounds ever appears. Must run from the bundle so LSUIElement
# applies.
verify-ui: app
	@"$(CONTENTS)/MacOS/$(BINARY)" --verify-ui

# Regression suite for the data layer — each was validated against live GitLab.
spikes:
	@echo "── auth ──"      && swift spike/AuthSpike.swift check
	@echo "── query ──"     && swift spike/QuerySpike.swift
	@echo "── poll ──"      && swift spike/PollSpike.swift
	@echo "── screen ──"    && swift spike/ScreenSpike.swift
	@echo "── scope ──"     && swift spike/ScopeVerify.swift
	@echo "── stale ──"     && swift spike/StaleFilterVerify.swift
	@echo "── centering ──" && swift spike/CenteringVerify.swift
	@echo "── notch ──"     && swift spike/NotchPlacementVerify.swift

# The geometry spikes need no network or token, so they are safe to run in CI
# or on a machine that has never been signed in.
spikes-offline:
	@echo "── centering ──" && swift spike/CenteringVerify.swift
	@echo "── notch ──"     && swift spike/NotchPlacementVerify.swift
	@echo "── screen ──"    && swift spike/ScreenSpike.swift

# Create a stable local signing identity so the keychain stops re-prompting on
# every rebuild. Run once; asks for the login password a single time.
# Record the README demo (GIF + MP4 + stills). Uses scripted data only.
demo-media: build
	@bash scripts/make-demo.sh

# Regenerate the app icon from scripts/make-icon.swift.
icon:
	@swift scripts/make-icon.swift
	@iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns
	@rm -rf AppIcon.iconset
	@echo "  built Resources/AppIcon.icns"

signing-identity:
	@bash scripts/create-signing-identity.sh

clean:
	rm -rf .build
