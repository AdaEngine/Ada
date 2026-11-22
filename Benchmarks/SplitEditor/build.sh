#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
output="$root/.build-tools/split-editor"
swift=${SPLIT_EDITOR_SWIFT:-"$HOME/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin/swift"}
if [[ ! -x "$swift" ]]; then swift=$(command -v swift); fi

export ADAENGINE_HEADLESS=0
args=(--package-path "$here" --scratch-path "$output/swift" -c release)
"$swift" build "${args[@]}" --product SplitEditor
bin=$("$swift" build "${args[@]}" --show-bin-path)
app="$output/Orbit Workspace.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/SplitEditor" "$app/Contents/MacOS/SplitEditor"
for resource in "$bin"/*.bundle; do
    [[ -d "$resource" ]] || continue
    name=$(basename "$resource")
    rsync -a "$resource/" "$app/Contents/Resources/$name/"
    ln -sfn "../Resources/$name" "$app/Contents/MacOS/$name"
done
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SplitEditor</string>
<key>CFBundleIdentifier</key><string>org.adaengine.benchmarks.spliteditor</string>
<key>CFBundleName</key><string>Orbit Workspace</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
codesign --verify "$app"
printf '%s\n' "$app"
