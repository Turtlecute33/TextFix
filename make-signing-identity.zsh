#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
#
# Creates the self-signed code signing identity for macOS releases (run once). With the same
# identity in every release, the designated requirement of the app stays the same, so macOS keeps
# the Accessibility permission and the keychain access of TextFix after an update.
#
# Releases are built in GitHub Actions, so the identity goes to two places:
#  - the repository secrets MACOS_SIGN_P12 and MACOS_SIGN_P12_PASSWORD. Only the release
#    workflow passes them to the build.
#  - a backup keychain, ~/.config/textfix/macos-signing.keychain-db. It locks after 5 minutes and
#    when the Mac sleeps. Its random password goes into the login Keychain (service
#    "textfix-macos-signing") with no trusted app. GitHub never gives a secret back, so keep a copy
#    of this file: a new identity means one more permission grant for every user.
#
# To put the backup into the secrets again (a new repository, a lost secret), export it with
# Keychain Access or `security export`, and pipe it to `gh secret set` as below.
set -euo pipefail
repo=Turtlecute33/TextFix
dir=$HOME/.config/textfix
kc=$dir/macos-signing.keychain-db
[[ -e $kc ]] && { print -u2 "Already exists: $kc"; exit 1 }
command -v gh >/dev/null || { print -u2 "gh is needed to store the CI secrets"; exit 1 }
mkdir -p -m 700 $dir
tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT
pw=$(/usr/bin/openssl rand -base64 30)

# macOS LibreSSL: its PKCS#12 format is what `security import` reads.
/usr/bin/openssl req -x509 -newkey rsa:3072 -nodes -days 7300 -subj "/CN=TextFix" \
  -addext "basicConstraints=critical,CA:false" -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" -keyout $tmp/key.pem -out $tmp/cert.pem 2>/dev/null
# The password goes on stdin, never as an argument: other processes can read the arguments of a
# process. A pipe, not <<<: zsh writes a here-string to a temporary file.
print -r -- "$pw" | /usr/bin/openssl pkcs12 -export -name TextFix -inkey $tmp/key.pem -in $tmp/cert.pem \
  -out $tmp/identity.p12 -passout stdin

# create-keychain adds the new keychain to the search list. Codesign gets it by path, so the
# search list goes back to what it was.
searchlist=("${(@f)$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//')}")
# -U keeps the access list of an old item, so delete it first.
security delete-generic-password -s textfix-macos-signing -a keychain >/dev/null 2>&1 || true
{
  print -r -- "create-keychain -p \"$pw\" \"$kc\""
  print -r -- "unlock-keychain -p \"$pw\" \"$kc\""
  print -r -- "import \"$tmp/identity.p12\" -k \"$kc\" -P \"$pw\" -T /usr/bin/codesign"
  print -r -- "set-key-partition-list -S apple-tool:,apple: -s -k \"$pw\" \"$kc\""
  print -r -- "add-generic-password -T \"\" -s textfix-macos-signing -a keychain -l \"TextFix macOS signing keychain\" -w \"$pw\""
} | security -i >/dev/null
security list-keychains -d user -s "${searchlist[@]}"
security set-keychain-settings -lut 300 $kc
# security -i does not stop at a failed command: check the result.
identities=$(security find-identity -p codesigning $kc)
[[ $identities == *'"TextFix"'* ]] || { print -u2 "The identity was not imported"; exit 1 }
security find-generic-password -s textfix-macos-signing -a keychain >/dev/null || { print -u2 "The keychain password was not stored"; exit 1 }
print -r -- "$identities"
security lock-keychain $kc
print "Created $kc"

# The secrets go on stdin too.
base64 -i $tmp/identity.p12 | gh secret set MACOS_SIGN_P12 -R $repo
print -rn -- "$pw" | gh secret set MACOS_SIGN_P12_PASSWORD -R $repo
unset pw
print "Stored MACOS_SIGN_P12 and MACOS_SIGN_P12_PASSWORD in $repo"
