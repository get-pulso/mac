#!/bin/zsh

set -euo pipefail

project_root=${0:A:h:h}
derived_data_path=/tmp/pulso-derived-local
signing_identity="Developer ID Application: 21st Labs Inc. (25UG4QYN9F)"
expected_team="25UG4QYN9F"
build_lock=/tmp/pulso-local-build.lock

if ! mkdir "$build_lock" 2>/dev/null; then
    print -u2 "Another canonical Pulso build is already running."
    exit 1
fi
trap 'rmdir "$build_lock" 2>/dev/null || true' EXIT

if ! security find-identity -v -p codesigning | grep -F "$signing_identity" >/dev/null; then
    print -u2 "Missing signing identity: $signing_identity"
    exit 1
fi

cd "$project_root"
xcodegen generate
xcodebuild \
    -project Pulso.xcodeproj \
    -scheme Pulso \
    -configuration Debug \
    -derivedDataPath "$derived_data_path" \
    -disableAutomaticPackageResolution \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM=25UG4QYN9F \
    "CODE_SIGN_IDENTITY=$signing_identity" \
    "OTHER_CODE_SIGN_FLAGS=--timestamp=none" \
    build

app_path="$derived_data_path/Build/Products/Debug/Pulso.app"
signing_details=$(codesign -dv --verbose=4 "$app_path" 2>&1)
if ! grep -F "Authority=$signing_identity" <<<"$signing_details" >/dev/null ||
   ! grep -F "TeamIdentifier=$expected_team" <<<"$signing_details" >/dev/null; then
    print -u2 "Built app failed Developer ID verification."
    exit 1
fi
codesign --verify --deep --strict "$app_path"

print "$app_path"
