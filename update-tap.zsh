#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
#
# Points the Homebrew cask (github.com/Turtlecute33/homebrew-tap) to a published release. It
# writes the whole cask from the template below each time, so a change here reaches the tap.
# Run it once the release workflow has attached TextFix-macos-universal.zip to v<version>:
#   ./update-tap.zsh 1.2.0
set -euo pipefail
version=${1:?usage: ./update-tap.zsh <version>}
zip=TextFix-macos-universal.zip
tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT

# The hash of the file that users download, not of a local build.
gh release download v$version -R Turtlecute33/TextFix -p $zip -D $tmp
sha=$(shasum -a 256 $tmp/$zip | cut -d' ' -f1)

gh repo clone Turtlecute33/homebrew-tap $tmp/tap -- --quiet --depth 1
cask=$tmp/tap/Casks/textfix.rb
mkdir -p ${cask:h}
cat > $cask <<'CASK'
cask "textfix" do
  version ""
  sha256 ""

  url "https://github.com/Turtlecute33/TextFix/releases/download/v#{version}/TextFix-macos-universal.zip"
  name "TextFix"
  desc "Fix the text in any text box with one hotkey and your own AI key"
  homepage "https://github.com/Turtlecute33/TextFix"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :ventura

  app "TextFix.app"

  uninstall quit: "com.turtlecute33.textfix"

  # The script deletes the API keys (one item per provider) from the login Keychain.
  zap script: {
        executable:   "/bin/sh",
        args:         [
          "-c",
          "while /usr/bin/security delete-generic-password -s com.turtlecute33.textfix >/dev/null 2>&1; do :; done",
        ],
        must_succeed: false,
      },
      trash:  [
        "~/Library/Application Support/TextFix",
        "~/Library/Logs/TextFix",
      ]

  caveats <<~EOS
    TextFix needs Accessibility permission:
      System Settings > Privacy & Security > Accessibility

    Each release has a new signature, so after an upgrade macOS treats TextFix as a new app.
    Remove the old TextFix entry in that list with the minus button, and add the new one.
  EOS
end
CASK
sed -i '' -e "s/^  version \".*\"/  version \"$version\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" $cask
git -C $tmp/tap add Casks/textfix.rb
if git -C $tmp/tap diff --cached --quiet; then
  print "The cask is already at $version."
  exit 0
fi
git -C $tmp/tap commit --quiet -m "textfix $version"
git -C $tmp/tap push --quiet
print "Cask updated: textfix $version ($sha)"
