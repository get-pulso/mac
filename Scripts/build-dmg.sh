#!/bin/zsh

# Builds the Firstlight disk image with a styled Finder window: the rendered
# background, the app on the left, an Applications link on the right.
#
# Usage: Scripts/build-dmg.sh <Firstlight.app> <out.dmg> [--sign]
#
# Finder keeps the window layout in the volume's .DS_Store, so the image is
# first created read-write, laid out through Finder itself, then converted to
# a compressed read-only image. --sign codesigns the result with the Developer
# ID identity; notarization and stapling stay with release.sh.

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}

app_path=${1:?usage: build-dmg.sh <Firstlight.app> <out.dmg> [--sign]}
out_dmg=${2:?usage: build-dmg.sh <Firstlight.app> <out.dmg> [--sign]}
sign=false
[[ ${3:-} == --sign ]] && sign=true

volume_name="Firstlight"
signing_identity="Developer ID Application: 21st Labs Inc. (25UG4QYN9F)"

# Window geometry in points. The background is rendered at exactly this size.
window_x=200 window_y=140 window_w=660 window_h=400
icon_size=128
app_pos_x=165 app_pos_y=190
apps_pos_x=495 apps_pos_y=190

fail() { print -u2 "build-dmg: $*"; exit 1; }
for tool in hdiutil tiffutil rsvg-convert swift osascript SetFile; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing $tool"
done
[[ -d "$app_path" ]] || fail "app not found: $app_path"

work=$(mktemp -d /tmp/firstlight-dmg.XXXXXX)
staging="$work/staging"
mkdir -p "$staging/.background"
cleanup() {
    if [[ -n ${mount_point:-} && -d $mount_point ]]; then
        hdiutil detach "$mount_point" -quiet 2>/dev/null || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT

# 1. Background: 1x and 2x PNG packed into one TIFF so Finder picks the Retina rep.
rsvg-convert -h 512 "$project_root/Design/firstlight-mark.svg" -o "$work/mark.png"
swift "$script_dir/dmg/render-background.swift" "$work/mark.png" 1 "$work/bg.png"
swift "$script_dir/dmg/render-background.swift" "$work/mark.png" 2 "$work/bg@2x.png"
tiffutil -cathidpicheck "$work/bg.png" "$work/bg@2x.png" -out "$staging/.background/background.tiff" >/dev/null

# 2. Contents. The app icon doubles as the volume icon on the desktop.
ditto "$app_path" "$staging/$volume_name.app"
ln -s /Applications "$staging/Applications"
volume_icon="$app_path/Contents/Resources/AppIcon.icns"
[[ -f "$volume_icon" ]] || fail "app has no AppIcon.icns for the volume icon"
cp "$volume_icon" "$staging/.VolumeIcon.icns"

# 3. Read-write image, sized to the contents with headroom for .DS_Store and the icon cache.
size_kb=$(( $(du -sk "$staging" | cut -f1) + 20480 ))
rw_dmg="$work/rw.dmg"
hdiutil create -quiet -srcfolder "$staging" -volname "$volume_name" -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" -format UDRW -size "${size_kb}k" "$rw_dmg"

mount_point="/Volumes/$volume_name"
if [[ -d "$mount_point" ]]; then
    hdiutil detach "$mount_point" -quiet 2>/dev/null || fail "another volume is mounted at $mount_point"
fi
hdiutil attach -quiet -readwrite -noverify -noautoopen "$rw_dmg" -mountpoint "$mount_point"

# Mark the root as having a custom icon before Finder touches the volume:
# without the flag, Finder discards .VolumeIcon.icns while laying out the window.
SetFile -a C "$mount_point"
SetFile -a V "$mount_point/.VolumeIcon.icns"

# 4. Let Finder write the layout into .DS_Store.
osascript - "$volume_name" "$window_x" "$window_y" "$window_w" "$window_h" "$icon_size" \
    "$app_pos_x" "$app_pos_y" "$apps_pos_x" "$apps_pos_y" <<'APPLESCRIPT'
on run argv
    set volumeName to item 1 of argv
    set {wx, wy, ww, wh, iconSize} to {item 2 of argv as integer, item 3 of argv as integer, item 4 of argv as integer, item 5 of argv as integer, item 6 of argv as integer}
    set {appX, appY, appsX, appsY} to {item 7 of argv as integer, item 8 of argv as integer, item 9 of argv as integer, item 10 of argv as integer}
    tell application "Finder"
        tell disk volumeName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set pathbar visible of container window to false
            set sidebar width of container window to 0
            set bounds of container window to {wx, wy, wx + ww, wy + wh}
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to iconSize
            set text size of viewOptions to 13
            set label position of viewOptions to bottom
            set shows item info of viewOptions to false
            set shows icon preview of viewOptions to true
            set background picture of viewOptions to file ".background:background.tiff"
            set position of item (volumeName & ".app") of container window to {appX, appY}
            set position of item "Applications" of container window to {appsX, appsY}
            close
            -- Reopening flushes the layout into .DS_Store. Finder's "update"
            -- verb is deliberately not used: it deletes .VolumeIcon.icns.
            open
            delay 1
            close
        end tell
    end tell
end run
APPLESCRIPT

# 5. Hide the helpers, flush, detach.
SetFile -a V "$mount_point/.background" 2>/dev/null || chflags hidden "$mount_point/.background"
chflags hidden "$mount_point/.fseventsd" 2>/dev/null || true
sync
hdiutil detach "$mount_point" -quiet
unset mount_point

# 6. Compress to the read-only image (LZFSE, readable on macOS 10.11+).
rm -f "$out_dmg"
hdiutil convert -quiet "$rw_dmg" -format ULFO -o "$out_dmg"

if $sign; then
    codesign --force --sign "$signing_identity" --timestamp "$out_dmg"
    codesign --verify --verbose=2 "$out_dmg"
fi

print -r -- "built $out_dmg"
