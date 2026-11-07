#!/bin/zsh
# Regenerates the app icon PNGs from Tools/AppIconArtwork.swift and the pigeon
# drawing in StopThePigeon/SplashView.swift.
set -euo pipefail

ROOT=${0:A:h:h}
OUT="$ROOT/StopThePigeon/Assets.xcassets/AppIcon.appiconset"
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

# Strip the #Preview block, which needs Xcode's preview macros.
sed '/^#Preview {/,$d' "$ROOT/StopThePigeon/SplashView.swift" > "$BUILD/SplashView.swift"
swiftc -O -parse-as-library -o "$BUILD/make-icon" \
    "$ROOT/Tools/MakeIcon.swift" "$ROOT/Tools/AppIconArtwork.swift" "$BUILD/SplashView.swift"
"$BUILD/make-icon" "$OUT"
