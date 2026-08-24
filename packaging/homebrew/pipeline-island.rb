# Homebrew cask for Pipeline Island.
#
# Builds from source on the user's machine rather than shipping a prebuilt
# binary. That is deliberate: without a paid Apple Developer ID the app can only
# be ad-hoc signed, and macOS refuses to open a *downloaded* ad-hoc app at all
# ("Pipeline Island is damaged and can't be opened"). An app compiled locally
# never gets the quarantine attribute, so it just works.
#
# To publish:
#   1. create a repo named `homebrew-tap` on GitHub
#   2. put this file at Casks/pipeline-island.rb
#   3. users then run:  brew install --cask Uudg/tap/pipeline-island
#
# Update `version` and `sha256` on each release — the CI workflow prints the
# sha256 of the source tarball for exactly this.

cask "pipeline-island" do
  version "1.0.0"
  sha256 "REPLACE_WITH_SHA256_FROM_RELEASE"

  url "https://github.com/Uudg/pipeline-island/archive/refs/tags/v#{version}.tar.gz"
  name "Pipeline Island"
  desc "Live GitLab CI pipeline status in the macOS notch"
  homepage "https://github.com/Uudg/pipeline-island"

  depends_on macos: ">= :sonoma"

  # Build from source. Xcode's Swift toolchain is required; the Command Line
  # Tools alone are enough.
  preflight do
    system_command "/usr/bin/make",
                   args: ["app"],
                   chdir: staged_path/"pipeline-island-#{version}",
                   print_stderr: true
  end

  app "pipeline-island-#{version}/.build/debug/PipelineIsland.app"

  postflight do
    puts <<~EOS

      Pipeline Island is installed.

      Two things to do:

        1. Open it, click the menu bar icon, and add a GitLab token
           with the `read_api` scope. Settings links straight to the
           token page.

        2. macOS will ask for keychain access once. That prompt is the
           point: the app cannot read your token without your consent.

    EOS
  end

  zap trash: [
    "~/Library/Preferences/com.pipelineisland.app.plist",
  ]

  caveats do
    <<~EOS
      Pipeline Island is built from source during installation, so it is never
      quarantined by Gatekeeper. This requires a Swift toolchain — install
      Xcode or the Command Line Tools first:

        xcode-select --install

      Your GitLab token is stored in the macOS Keychain, never on disk. To
      remove it completely, use "Remove Token" in Settings before uninstalling.
    EOS
  end
end
