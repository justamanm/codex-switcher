#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h:h}"
app_path="$root_dir/dist/Codex Switcher.app"
output_path="$root_dir/dist/Codex-Switcher.dmg"
staging_root="$(mktemp -d /private/tmp/codex-switcher-dmg.XXXXXX)"
volume_root="$staging_root/Codex Switcher"
temporary_dmg="$staging_root/Codex-Switcher.dmg"

cleanup() {
    if [[ "$staging_root" == /private/tmp/codex-switcher-dmg.* ]]; then
        rm -rf "$staging_root"
    fi
}
trap cleanup EXIT

"$root_dir/scripts/build-app.sh"
codesign --verify --deep --strict "$app_path"
test -x "$app_path/Contents/MacOS/CodexSwitcher"
test -f "$app_path/Contents/Resources/AppIcon.icns"

mkdir -p "$volume_root"
ditto "$app_path" "$volume_root/Codex Switcher.app"
ln -s /Applications "$volume_root/Applications"

hdiutil create \
    -volname "Codex Switcher" \
    -srcfolder "$volume_root" \
    -format UDZO \
    -ov \
    "$temporary_dmg" >/dev/null

mkdir -p "$root_dir/dist"
mv -f "$temporary_dmg" "$output_path"
print "已生成：$output_path"
