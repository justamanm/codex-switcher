#!/bin/zsh
set -euo pipefail

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/codex-switcher-module-cache}"

root_dir="${0:A:h:h}"
app_dir="$root_dir/dist/Codex Switcher.app"
staging_root="$(mktemp -d "$root_dir/dist/.codex-switcher-build.XXXXXX")"
staging_app="$staging_root/Codex Switcher.app"

cd "$root_dir"
sips -z 16 16 "$root_dir/support/AppIcon.png" --out "$root_dir/support/AppIcon.iconset/icon_16x16.png" >/dev/null
sips -z 32 32 "$root_dir/support/AppIcon.png" --out "$root_dir/support/AppIcon.iconset/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$root_dir/support/AppIcon.png" --out "$root_dir/support/AppIcon.iconset/icon_32x32.png" >/dev/null
sips -z 64 64 "$root_dir/support/AppIcon.png" --out "$root_dir/support/AppIcon.iconset/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$root_dir/support/AppIcon.png" --out "$root_dir/support/AppIcon.iconset/icon_128x128.png" >/dev/null
sips -z 256 256 "$root_dir/support/AppIcon.png" --out "$root_dir/support/AppIcon.iconset/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$root_dir/support/AppIcon.png" --out "$root_dir/support/AppIcon.iconset/icon_256x256.png" >/dev/null
sips -z 512 512 "$root_dir/support/AppIcon.png" --out "$root_dir/support/AppIcon.iconset/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$root_dir/support/AppIcon.png" --out "$root_dir/support/AppIcon.iconset/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$root_dir/support/AppIcon.png" --out "$root_dir/support/AppIcon.iconset/icon_512x512@2x.png" >/dev/null
node "$root_dir/scripts/make-icns.mjs"
if [[ "${CODEX_SWITCHER_SKIP_SWIFT_BUILD:-0}" != "1" ]]; then
    swift build --disable-sandbox -c release
fi
binary="$root_dir/.build/release/CodexSwitcher"
mkdir -p "$staging_app/Contents/MacOS"
mkdir -p "$staging_app/Contents/Resources"
install -m 755 "$binary" "$staging_app/Contents/MacOS/CodexSwitcher"
install -m 644 "$root_dir/support/Info.plist" "$staging_app/Contents/Info.plist"
install -m 644 "$root_dir/support/PkgInfo" "$staging_app/Contents/PkgInfo"
install -m 644 "$root_dir/support/AppIcon.icns" "$staging_app/Contents/Resources/AppIcon.icns"
install -m 644 "$root_dir/support/AppIcon.png" "$staging_app/Contents/Resources/AppIcon.png"
codesign --force --deep --sign - "$staging_app"
if [[ -d "$app_dir" ]]; then
    old_root="$(mktemp -d /private/tmp/codex-switcher-previous.XXXXXX)"
    mv "$app_dir" "$old_root/Codex Switcher.previous-bundle"
fi
mv "$staging_app" "$app_dir"
rmdir "$staging_root"
print "已生成：$app_dir"
