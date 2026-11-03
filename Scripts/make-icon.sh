#!/usr/bin/env bash
# Compiles Resources/AppIcon.icon (the Icon Composer document) into the two
# files the bundle carries: Assets.car for the Liquid Glass icon macOS 26
# draws, and AppIcon.icns for older systems. Both are committed, so building
# the app never needs Xcode's actool. Run after editing the icon.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

TMP="$(mktemp -d)"
xcrun actool Resources/AppIcon.icon --compile "${TMP}" \
  --app-icon AppIcon --platform macosx --minimum-deployment-target 14.0 \
  --output-partial-info-plist "${TMP}/partial.plist" >/dev/null
cp "${TMP}/Assets.car" Resources/Assets.car

# actool's own .icns stops at 128pt, which older systems blow up for the Dock
# and Finder; render every size from the same document instead.
ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
ICONSET="${TMP}/AppIcon.iconset"
mkdir -p "${ICONSET}"
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    name="icon_${size}x${size}"; [ "${scale}" = 2 ] && name="${name}@2x"
    "${ICTOOL}" Resources/AppIcon.icon --export-image --output-file "${ICONSET}/${name}.png" \
      --platform macOS --rendition Default --width "${size}" --height "${size}" --scale "${scale}" >/dev/null
  done
done
iconutil -c icns "${ICONSET}" -o Resources/AppIcon.icns
echo "Wrote Resources/Assets.car and Resources/AppIcon.icns"
rm -rf "${TMP}"
