#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Build the native Qt Linux agent; --zip produces a release archive.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
variant=linux
version=0.0.0
archive=false
tests=false
while (($#)); do
    case "$1" in
        --omarchy) variant=omarchy ; shift ;;
        --zip) archive=true; shift ;;
        --test) tests=true; shift ;;
        --version) version="${2:?--version requires a value}"; shift 2 ;;
        -h|--help) echo "Usage: ./build-linux.sh [--omarchy] [--zip] [--test] [--version 1.2.3]"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
[[ "$(uname -s)" == Linux ]] || { echo "This build requires Linux." >&2; exit 1; }
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || { echo "Invalid version: $version" >&2; exit 2; }
case "$(uname -m)" in
    x86_64) arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac
qmake="${QMAKE:-qmake6}"
command -v "$qmake" >/dev/null || { echo "Install Qt 6 development tools (qmake6, Qt Quick, Qt DBus, Qt SVG)." >&2; exit 1; }
# qmake/make do not rebuild objects merely because a compiler define changed. Keep versions
# in separate directories so a release can never reuse a binary stamped with an older version.
build="$root/build/linux-$arch/$version"
mkdir -p "$build"
cd "$build"
"$qmake" "$root/src/TextFixLinux/textfix.pro" "TEXTFIX_VERSION=$version"
make -s -j"${JOBS:-$(nproc)}"
[[ "$("$build/textfix" --version)" == "TextFix $version" ]] || { echo "Binary version does not match $version" >&2; exit 1; }
if $tests; then
    mkdir -p tests
    cd tests
    "$qmake" "$root/src/TextFixLinux/tests/tests.pro"
    make -s -j"${JOBS:-$(nproc)}"
    QT_QPA_PLATFORMTHEME= QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software ./textfix_tests
    cd "$build"
fi
output="$root/dist/$variant-$arch"
mkdir -p "$output"
install -m755 "$build/textfix" "$output/textfix"
strip "$output/textfix"
install -m755 "$root/packaging/linux/install.sh" "$output/install.sh"
install -m644 "$root/packaging/linux/textfix.desktop" "$root/packaging/linux/textfix.svg" "$root/LICENSE" "$output/"
sed '/^!\[TextFix Linux settings\]/d' "$root/src/TextFixLinux/README.md" > "$output/README.md"
if [[ "$variant" == omarchy ]]; then
    mkdir -p "$output/omarchy"
    install -m644 "$root/packaging/omarchy/textfix.lua" "$root/packaging/omarchy/textfix.conf" "$root/packaging/omarchy/PKGBUILD" "$output/omarchy/"
fi
if $archive; then
    archive_path="$root/TextFix-$variant-$arch.zip"
    # zip updates old archives, so always create a fresh one with exactly this build's files.
    archive_directory="$(mktemp -d "$root/.textfix-archive.XXXXXX")"
    trap 'rmdir "$archive_directory" 2>/dev/null || true' EXIT
    temporary_archive="$archive_directory/release.zip"
    (cd "$output" && zip -qr "$temporary_archive" .)
    mv -f "$temporary_archive" "$archive_path"
    echo "Packaged $archive_path"
fi
echo "Built $output/textfix ($version)"
