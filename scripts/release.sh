#!/bin/bash
# Cut a release and update the Homebrew cask in one command.
#
# The cask pins an exact version and sha256, so shipping an update is a
# five-step dance: tag, wait for CI to publish the release, download the
# tarball GitHub generated, hash it, then commit the new version and hash to
# the tap. Doing that by hand already produced one broken cask — a re-cut tag
# changed the tarball and the stale sha256 made `brew install` fail its
# checksum for everyone.
#
# Usage:  ./scripts/release.sh 1.0.1

set -euo pipefail

VERSION="${1:-}"
REPO="Uudg/pipeline-island"
TAP_REPO="Uudg/homebrew-tap"
CASK="Casks/pipeline-island.rb"

if [ -z "$VERSION" ]; then
    echo "usage: $0 <version>    e.g. $0 1.0.1" >&2
    exit 1
fi
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "version must look like 1.2.3, got '$VERSION'" >&2
    exit 1
fi

cd "$(dirname "$0")/.."

# --- preflight ---------------------------------------------------------
if [ -n "$(git status --porcelain)" ]; then
    echo "working tree is dirty — commit or stash first" >&2
    git status --short >&2
    exit 1
fi

if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    echo "tag v$VERSION already exists" >&2
    exit 1
fi

echo "==> building and testing before tagging"
swift build
swift spike/CenteringVerify.swift >/dev/null
swift spike/NotchPlacementVerify.swift >/dev/null
make app >/dev/null
echo "    ok"

# --- tag ---------------------------------------------------------------
echo "==> tagging v$VERSION"
git push -q origin main
git tag -a "v$VERSION" -m "v$VERSION"
git push -q origin "v$VERSION"

# --- wait for CI to publish the release --------------------------------
echo "==> waiting for CI to publish the release"
for _ in $(seq 1 60); do
    if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
        echo "    release published"
        break
    fi
    sleep 10
done

if ! gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
    echo "release never appeared — check: gh run list --repo $REPO" >&2
    exit 1
fi

# --- hash the tarball GitHub actually serves ---------------------------
# Hash what GitHub serves, not a locally built archive: they are not
# byte-identical, and the cask is checked against the served file.
echo "==> hashing the published tarball"
TARBALL=$(mktemp)
trap 'rm -f "$TARBALL"' EXIT
curl -fsSL -o "$TARBALL" \
    "https://github.com/$REPO/archive/refs/tags/v$VERSION.tar.gz"
SHA=$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)
echo "    $SHA"

# --- update the tap ----------------------------------------------------
echo "==> updating the cask"
TAP_DIR=$(mktemp -d)
trap 'rm -f "$TARBALL"; rm -rf "$TAP_DIR"' EXIT
gh repo clone "$TAP_REPO" "$TAP_DIR" -- -q

cd "$TAP_DIR"
/usr/bin/sed -i '' "s|^  version \".*\"|  version \"$VERSION\"|" "$CASK"
/usr/bin/sed -i '' "s|^  sha256 \".*\"|  sha256 \"$SHA\"|" "$CASK"

if [ -z "$(git status --porcelain)" ]; then
    echo "    cask already up to date"
else
    git add "$CASK"
    git commit -q -m "pipeline-island $VERSION"
    git push -q
    echo "    pushed"
fi

# --- verify the cask actually resolves ---------------------------------
echo "==> verifying"
brew update-reset "$(brew --repository)/Library/Taps/uudg/homebrew-tap" >/dev/null 2>&1 || true
brew tap uudg/tap >/dev/null 2>&1 || true
INSTALLED_SHA=$(grep -oE '[a-f0-9]{64}' "$(brew --repository)/Library/Taps/uudg/homebrew-tap/$CASK" || echo "")
if [ "$INSTALLED_SHA" = "$SHA" ]; then
    echo "    tap serves the correct sha256"
else
    echo "    WARNING: tap sha ($INSTALLED_SHA) != release sha ($SHA)" >&2
    echo "    it may just need a moment to propagate; re-check with:" >&2
    echo "      brew info --cask Uudg/tap/pipeline-island" >&2
fi

echo
echo "v$VERSION is out. Users update with:"
echo "  brew upgrade --cask pipeline-island"
