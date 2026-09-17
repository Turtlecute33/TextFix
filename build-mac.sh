#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# Builds the macOS agent into ./dist/macos/TextFix.app and, with --zip, packages it for release.
#
#   ./build-mac.sh                    # -> dist/macos/TextFix.app (universal)
#   ./build-mac.sh --zip              # -> TextFix-macos-universal.zip
#   ./build-mac.sh --run              # build and start it
#   ./build-mac.sh --arch arm64       # single-architecture build
#   ./build-mac.sh --version 1.1.0    # stamp a version into Info.plist
#
# The counterpart of build.ps1 on the Windows side. Needs the Xcode command line tools and
# nothing else: no package manager, no dependencies, no code signing certificate.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package="$root/src/TextFixMac"
output="$root/dist/macos"
app="$output/TextFix.app"

configuration="release"
version="0.0.0"
zip=false
run=false
archs=(arm64 x86_64)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --zip) zip=true; shift ;;
        --run) run=true; shift ;;
        --version) version="$2"; shift 2 ;;
        --arch) archs=("$2"); shift 2 ;;
        --debug) configuration="debug"; shift ;;
        -h|--help) sed -n '3,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "build-mac.sh only runs on macOS. Use build.ps1 for the Windows agent." >&2
    exit 1
fi
command -v swift >/dev/null || { echo "swift was not found. Install the Xcode command line tools: xcode-select --install" >&2; exit 1; }

arch_flags=()
for arch in "${archs[@]}"; do arch_flags+=(--arch "$arch"); done
arch_label="$(IFS=-; echo "${archs[*]}")"
if [[ ${#archs[@]} -gt 1 ]]; then arch_label="universal"; fi

echo "==> Building $configuration for ${archs[*]}"
swift build --package-path "$package" -c "$configuration" "${arch_flags[@]}"

bin_path="$(swift build --package-path "$package" -c "$configuration" "${arch_flags[@]}" --show-bin-path)"
binary="$bin_path/TextFix"
[[ -f "$binary" ]] || { echo "build produced no binary at $binary" >&2; exit 1; }

echo "==> Assembling $app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "$binary" "$app/Contents/MacOS/TextFix"
# Symbols are a third of the binary and nothing reads them in a release the user downloads.
if [[ "$configuration" == "release" ]]; then strip -x "$app/Contents/MacOS/TextFix"; fi

sed "s/__VERSION__/$version/g" "$package/Resources/Info.plist" > "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"

echo "==> Drawing the icon"
iconset="$(mktemp -d)/AppIcon.iconset"
swift "$package/Tools/makeicon.swift" "$iconset" >/dev/null
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$iconset")"

# Signing. A Developer ID is used when the workflow supplies one; otherwise the bundle is ad-hoc
# signed, which is what lets macOS remember the Accessibility permission between launches. It does
# not get the app past Gatekeeper on another machine - see the README for the one-time
# right-click > Open, which is the honest cost of shipping without a $99/year account.
#
# Both paths get the hardened runtime. It is usually thought of as a notarisation prerequisite, but
# the protections it turns on are real on their own: no DYLD injection, no unsigned code in the
# process, no attaching a debugger. For an app the user grants Accessibility to - the most powerful
# permission on the system - those are worth having whether or not Apple has stamped the bundle.
# Nothing here needs an entitlement to go with it: Accessibility is gated by TCC, not by the
# hardened runtime, and the app uses no AppleEvents, no camera and no microphone.
identity="${MACOS_SIGN_IDENTITY:--}"
# Written out twice rather than assembled from a flag array: expanding an empty array under
# `set -u` is an error in the bash macOS ships, and the two commands differ by one flag.
if [[ "$identity" == "-" ]]; then
    echo "==> Ad-hoc signing"
    codesign --force --sign - --identifier com.turtlecute33.textfix --options runtime "$app"
else
    echo "==> Signing with $identity"
    codesign --force --sign "$identity" --identifier com.turtlecute33.textfix \
        --options runtime --timestamp "$app"
fi
codesign --verify --strict "$app"

size_kb=$(( $(stat -f%z "$app/Contents/MacOS/TextFix") / 1024 ))
echo "==> Built TextFix.app (${size_kb} KB binary, ${arch_label})"

if $zip; then
    archive="$root/TextFix-macos-$arch_label.zip"
    rm -f "$archive"
    # ditto rather than zip: it is the only archiver that preserves the code signature and the
    # bundle's extended attributes, so the app still verifies after a download.
    ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
    echo "==> Packaged $archive"
fi

if $run; then
    pkill -x TextFix 2>/dev/null || true
    open "$app"
    echo "==> Agent started; look for the menu bar icon."
fi
