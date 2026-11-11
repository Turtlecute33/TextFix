#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Install the extracted Linux release for this user, or stage it with --prefix/--destdir.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
prefix="${HOME}/.local"
destdir=""
while (($#)); do
    case "$1" in
        --prefix) prefix="${2:?--prefix requires a path}"; shift 2 ;;
        --destdir) destdir="${2:?--destdir requires a path}"; shift 2 ;;
        *) echo "Usage: ./install.sh [--prefix /usr] [--destdir staging-directory]" >&2; exit 2 ;;
    esac
done
[[ "$prefix" = /* ]] || { echo "--prefix must be absolute" >&2; exit 2; }
install -Dm755 "$root/textfix" "$destdir$prefix/bin/textfix"
install -Dm644 "$root/textfix.desktop" "$destdir$prefix/share/applications/textfix.desktop"
install -Dm644 "$root/textfix.svg" "$destdir$prefix/share/icons/hicolor/scalable/apps/textfix.svg"
install -Dm644 "$root/LICENSE" "$destdir$prefix/share/licenses/textfix/LICENSE"
if [[ -d "$root/omarchy" ]]; then
    install -Dm644 "$root/omarchy/textfix.lua" "$destdir$prefix/share/textfix/omarchy/textfix.lua"
    install -Dm644 "$root/omarchy/textfix.conf" "$destdir$prefix/share/textfix/omarchy/textfix.conf"
fi
echo "Installed TextFix in $destdir$prefix. Run textfix settings to configure it."
