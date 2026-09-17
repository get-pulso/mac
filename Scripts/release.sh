#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
project_file="$project_root/project.yml"
info_plist="$project_root/App/Resources/Info.plist"

source_repo=${FIRSTLIGHT_SOURCE_REPO:-get-pulso/mac}
releases_repo=${FIRSTLIGHT_RELEASES_REPO:-get-pulso/mac-releases}
releases_repo_url=${FIRSTLIGHT_RELEASES_REPO_URL:-https://github.com/${releases_repo}.git}
# The app polls this URL; firstlight.sh rewrites /appcast.xml to the published feed below.
feed_url=${FIRSTLIGHT_APPCAST_URL:-https://firstlight.sh/appcast.xml}
# Where releases are actually published, and the source of truth this script appends to.
# Firstlight has a feed file of its own: appcast.xml next to it belongs to the last
# Pulso build, which must never be offered an update it cannot verify.
feed_file=${FIRSTLIGHT_FEED_FILE:-firstlight.xml}
published_feed_url=${FIRSTLIGHT_PUBLISHED_APPCAST_URL:-https://get-pulso.github.io/mac-releases/${feed_file}}
notary_profile=${FIRSTLIGHT_NOTARY_PROFILE:-}
# Names the existing Sparkle EdDSA key in the Keychain. It kept its original
# account name through the Firstlight rename; changing it breaks update signing.
sparkle_account=${FIRSTLIGHT_SPARKLE_ACCOUNT:-pulso}
signing_identity="Developer ID Application: 21st Labs Inc. (25UG4QYN9F)"
team_id=25UG4QYN9F

publish=false
publish_prepared=false
preflight_only=false
notes_file=""

usage() {
    print -r -- "Usage: Scripts/release.sh [--check] [--publish|--publish-prepared] [--notes-file PATH] [--notary-profile NAME]"
    print -r -- ""
    print -r -- "Set and commit MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml first."
    print -r -- "--check validates source, version, signing key, and notarization credentials only."
    print -r -- "Without --publish, the notarized ZIP, the notarized DMG and the generated appcast are written to dist/<version>."
    print -r -- "--publish creates the GitHub Release, then publishes appcast.xml as the final step."
    print -r -- "--publish-prepared publishes reviewed artifacts already present in dist/<version>."
    print -r -- "Set FIRSTLIGHT_NOTARY_PROFILE and, when needed, FIRSTLIGHT_SPARKLE_ACCOUNT."
}

fail() {
    print -u2 "release: $*"
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

while (( $# > 0 )); do
    case "$1" in
        --check)
            preflight_only=true
            ;;
        --publish)
            publish=true
            ;;
        --publish-prepared)
            publish=true
            publish_prepared=true
            ;;
        --notes-file)
            (( $# >= 2 )) || fail "--notes-file requires a path"
            notes_file=$2
            shift
            ;;
        --notary-profile)
            (( $# >= 2 )) || fail "--notary-profile requires a Keychain profile name"
            notary_profile=$2
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "Unknown argument: $1"
            ;;
    esac
    shift
done

require_command awk
require_command codesign
require_command curl
require_command ditto
require_command git
require_command security
require_command shasum
require_command stat
require_command xcodebuild
require_command xcodegen
require_command xmllint
require_command xcrun
# Scripts/build-dmg.sh: background rendering, Retina TIFF packing and the Finder layout.
require_command rsvg-convert
require_command tiffutil
require_command swift
require_command osascript
require_command SetFile

[[ -f "$project_file" ]] || fail "Missing $project_file"
[[ -f "$info_plist" ]] || fail "Missing $info_plist"

release_version=$(awk '/^[[:space:]]*MARKETING_VERSION:/ { print $2; exit }' "$project_file")
release_build=$(awk '/^[[:space:]]*CURRENT_PROJECT_VERSION:/ { print $2; exit }' "$project_file")

[[ "$release_version" == <->.<->.<-> ]] || fail "MARKETING_VERSION must use x.y.z format"
[[ "$release_build" == <-> ]] || fail "CURRENT_PROJECT_VERSION must be an integer"
(( release_build > 0 )) || fail "CURRENT_PROJECT_VERSION must be positive"

if [[ -n "$notes_file" ]]; then
    notes_file=${notes_file:A}
    [[ -f "$notes_file" ]] || fail "Release notes not found: $notes_file"
fi
if $publish && ! $publish_prepared && [[ -z "$notes_file" ]]; then
    fail "--publish requires --notes-file"
fi

if [[ -n "$(git -C "$project_root" status --porcelain)" ]]; then
    fail "The mac worktree must be clean before preparing a release"
fi

public_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$info_plist" 2>/dev/null) || \
    fail "SUPublicEDKey is missing from Info.plist"
[[ -n "$public_key" ]] || fail "SUPublicEDKey is empty"

if ! $publish_prepared; then
    if ! security find-identity -v -p codesigning | grep -F "$signing_identity" >/dev/null; then
        fail "Missing signing identity: $signing_identity"
    fi
    if ! security find-generic-password \
        -s 'https://sparkle-project.org' \
        -a "$sparkle_account" >/dev/null 2>&1; then
        fail "Missing the existing Sparkle signing key '$sparkle_account' in the Keychain"
    fi

    [[ -n "$notary_profile" ]] || \
        fail "Set FIRSTLIGHT_NOTARY_PROFILE or pass --notary-profile"
    if ! xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1; then
        fail "Notary profile '$notary_profile' is missing or invalid"
    fi
fi

work_dir=$(mktemp -d "/tmp/firstlight-release.${release_version}.XXXXXX")
remote_appcast="$work_dir/current-appcast.xml"

cleanup() {
    if [[ "${FIRSTLIGHT_KEEP_RELEASE_WORKDIR:-0}" == "1" ]]; then
        print "Kept release workspace: $work_dir"
    else
        rm -rf -- "$work_dir"
    fi
}
trap cleanup EXIT

# The first release starts the feed; every later one is appended to it.
remote_status=$(curl -sSL --max-time 30 -o "$remote_appcast" -w '%{http_code}' "$published_feed_url") || \
    remote_status=000
case "$remote_status" in
    200)
        remote_build=$(xmllint --xpath \
            'string((//*[local-name()="item"]/*[local-name()="version"])[1])' \
            "$remote_appcast")
        [[ "$remote_build" == <-> ]] || fail "Could not read the current build from $published_feed_url"
        ;;
    404)
        rm -f "$remote_appcast"
        remote_build=0
        ;;
    *)
        fail "Could not fetch $published_feed_url (HTTP $remote_status)"
        ;;
esac
(( release_build > remote_build )) || \
    fail "Build $release_build must be greater than the published build $remote_build"

if $publish; then
    require_command gh
    [[ "$(git -C "$project_root" branch --show-current)" == "main" ]] || \
        fail "Publishing is allowed only from main"
    git -C "$project_root" fetch --quiet origin main
    [[ "$(git -C "$project_root" rev-parse HEAD)" == "$(git -C "$project_root" rev-parse origin/main)" ]] || \
        fail "Local main must exactly match origin/main before publishing"
    gh auth status >/dev/null
    if gh release view "$release_version" --repo "$source_repo" >/dev/null 2>&1; then
        fail "GitHub Release $release_version already exists"
    fi
fi

print "Release $release_version (build $release_build) passed preflight."
if $preflight_only; then
    exit 0
fi

output_dir="$project_root/dist/$release_version"
if $publish_prepared; then
    [[ -d "$output_dir" ]] || fail "Prepared output not found: $output_dir"
    release_zip="$output_dir/${release_version}.zip"
    release_dmg="$output_dir/${release_version}.dmg"
    prepared_appcast="$output_dir/appcast.xml"
    [[ -f "$release_zip" ]] || fail "Prepared ZIP not found: $release_zip"
    [[ -f "$release_dmg" ]] || fail "Prepared DMG not found: $release_dmg"
    [[ -f "$prepared_appcast" ]] || fail "Prepared appcast not found: $prepared_appcast"
    [[ -f "$output_dir/SHA256SUMS" ]] || fail "Prepared checksum file is missing"
    publish_notes_file="$output_dir/release-notes.txt"
    [[ -f "$publish_notes_file" ]] || fail "Prepared release notes are missing"
    (cd "$output_dir" && shasum -a 256 -c SHA256SUMS)

    prepared_app_dir="$work_dir/prepared-app"
    mkdir -p "$prepared_app_dir"
    ditto -x -k "$release_zip" "$prepared_app_dir"
    app_path=$(find "$prepared_app_dir" -maxdepth 2 -type d -name 'Firstlight.app' -print -quit)
    [[ -d "$app_path" ]] || fail "Prepared ZIP does not contain Firstlight.app"
    built_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
    built_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")
    [[ "$built_version" == "$release_version" ]] || fail "Prepared version is $built_version, expected $release_version"
    [[ "$built_build" == "$release_build" ]] || fail "Prepared build is $built_build, expected $release_build"
    codesign --verify --deep --strict --verbose=2 "$app_path"
    signing_details=$(codesign -dv --verbose=4 "$app_path" 2>&1)
    grep -F "Authority=$signing_identity" <<<"$signing_details" >/dev/null || fail "Prepared app has the wrong signer"
    grep -F "TeamIdentifier=$team_id" <<<"$signing_details" >/dev/null || fail "Prepared app has the wrong Team ID"
    xcrun stapler validate "$app_path"
    /usr/sbin/spctl -a -vv -t exec "$app_path"

    codesign --verify --verbose=2 "$release_dmg"
    dmg_signing_details=$(codesign -dv --verbose=4 "$release_dmg" 2>&1)
    grep -F "Authority=$signing_identity" <<<"$dmg_signing_details" >/dev/null || fail "Prepared DMG has the wrong signer"
    xcrun stapler validate "$release_dmg"
    /usr/sbin/spctl -a -vv -t open --context context:primary-signature "$release_dmg"

    generated_build=$(xmllint --xpath \
        'string((//*[local-name()="item"]/*[local-name()="version"])[1])' \
        "$prepared_appcast")
    generated_version=$(xmllint --xpath \
        'string((//*[local-name()="item"]/*[local-name()="shortVersionString"])[1])' \
        "$prepared_appcast")
    generated_url=$(xmllint --xpath \
        'string((//*[local-name()="item"]/*[local-name()="enclosure"])[1]/@url)' \
        "$prepared_appcast")
    generated_signature=$(xmllint --xpath \
        'string((//*[local-name()="item"]/*[local-name()="enclosure"])[1]/@*[local-name()="edSignature"])' \
        "$prepared_appcast")
    generated_length=$(xmllint --xpath \
        'string((//*[local-name()="item"]/*[local-name()="enclosure"])[1]/@length)' \
        "$prepared_appcast")
    expected_url="https://github.com/${source_repo}/releases/download/${release_version}/${release_version}.zip"
    archive_length=$(stat -f '%z' "$release_zip")
    [[ "$generated_build" == "$release_build" ]] || fail "Prepared appcast has the wrong build"
    [[ "$generated_version" == "$release_version" ]] || fail "Prepared appcast has the wrong version"
    [[ "$generated_url" == "$expected_url" ]] || fail "Prepared appcast has the wrong download URL"
    [[ "$generated_length" == "$archive_length" ]] || fail "Prepared appcast has the wrong archive length"
    [[ -n "$generated_signature" ]] || fail "Prepared appcast has no EdDSA signature"
else
    [[ ! -e "$output_dir" ]] || fail "Output already exists: $output_dir"

    derived_data="$work_dir/DerivedData"
    archive_path="$work_dir/Firstlight.xcarchive"

    (
        cd "$project_root"
        xcodegen generate
        FIRSTLIGHT_SKIP_SWIFTFORMAT=YES xcodebuild \
            -project Firstlight.xcodeproj \
            -scheme Firstlight \
            -configuration Release \
            -destination 'generic/platform=macOS' \
            -derivedDataPath "$derived_data" \
            -archivePath "$archive_path" \
            CODE_SIGN_STYLE=Manual \
            CODE_SIGNING_ALLOWED=YES \
            CODE_SIGNING_REQUIRED=YES \
            DEVELOPMENT_TEAM="$team_id" \
            "CODE_SIGN_IDENTITY=$signing_identity" \
            archive
    )

    app_path="$archive_path/Products/Applications/Firstlight.app"
    [[ -d "$app_path" ]] || fail "Archive did not contain Firstlight.app"

    built_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
    built_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")
    [[ "$built_version" == "$release_version" ]] || fail "Archived version is $built_version, expected $release_version"
    [[ "$built_build" == "$release_build" ]] || fail "Archived build is $built_build, expected $release_build"

    codesign --verify --deep --strict --verbose=2 "$app_path"
    signing_details=$(codesign -dv --verbose=4 "$app_path" 2>&1)
    grep -F "Authority=$signing_identity" <<<"$signing_details" >/dev/null || \
        fail "Archive is not signed by $signing_identity"
    grep -F "TeamIdentifier=$team_id" <<<"$signing_details" >/dev/null || \
        fail "Archive has the wrong Team ID"

    submission_zip="$work_dir/notary-submission.zip"
    ditto -c -k --sequesterRsrc --keepParent "$app_path" "$submission_zip"
    xcrun notarytool submit "$submission_zip" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$app_path"
    xcrun stapler validate "$app_path"
    codesign --verify --deep --strict --verbose=2 "$app_path"
    /usr/sbin/spctl -a -vv -t exec "$app_path"

    release_zip="$work_dir/${release_version}.zip"
    ditto -c -k --sequesterRsrc --keepParent "$app_path" "$release_zip"

    # The DMG carries the same stapled app in a styled Finder window. Sparkle
    # keeps updating from the ZIP; the DMG is what the website hands out.
    release_dmg="$work_dir/${release_version}.dmg"
    "$script_dir/build-dmg.sh" "$app_path" "$release_dmg" --sign
    xcrun notarytool submit "$release_dmg" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$release_dmg"
    xcrun stapler validate "$release_dmg"
    /usr/sbin/spctl -a -vv -t open --context context:primary-signature "$release_dmg"

    generate_appcast=$(find "$derived_data/SourcePackages/artifacts" -type f \
        -path '*/Sparkle/bin/generate_appcast' -perm -111 -print -quit)
    generate_keys=$(find "$derived_data/SourcePackages/artifacts" -type f \
        -path '*/Sparkle/bin/generate_keys' -perm -111 -print -quit)
    sign_update=$(find "$derived_data/SourcePackages/artifacts" -type f \
        -path '*/Sparkle/bin/sign_update' -perm -111 -print -quit)
    [[ -x "$generate_appcast" ]] || fail "Sparkle generate_appcast tool was not found"
    [[ -x "$generate_keys" ]] || fail "Sparkle generate_keys tool was not found"
    [[ -x "$sign_update" ]] || fail "Sparkle sign_update tool was not found"

    signing_public_key=$("$generate_keys" --account "$sparkle_account" -p) || \
        fail "Could not read Sparkle signing key '$sparkle_account' from the Keychain"
    [[ "$signing_public_key" == "$public_key" ]] || \
        fail "Sparkle signing key does not match SUPublicEDKey"

    # Sparkle's command-line tools may not inherit Keychain access granted to
    # generate_keys. Export into the private release workspace and point both
    # signing operations at the same short-lived key file.
    sparkle_private_key="$work_dir/sparkle-private-key"
    "$generate_keys" --account "$sparkle_account" -x "$sparkle_private_key" >/dev/null || \
        fail "Could not export Sparkle signing key '$sparkle_account'"
    chmod 600 "$sparkle_private_key"

    feed_dir="$work_dir/feed"
    mkdir -p "$feed_dir"
    if [[ -f "$remote_appcast" ]]; then
        cp "$remote_appcast" "$feed_dir/appcast.xml"
    fi
    cp "$release_zip" "$feed_dir/${release_version}.zip"
    if [[ -n "$notes_file" ]]; then
        cp "$notes_file" "$feed_dir/${release_version}.txt"
    fi

    appcast_args=(
        --ed-key-file "$sparkle_private_key"
        --download-url-prefix "https://github.com/${source_repo}/releases/download/${release_version}/"
        --link "https://github.com/${source_repo}/releases/tag/${release_version}"
        --full-release-notes-url "https://github.com/${source_repo}/releases"
        --versions "$release_build"
        --maximum-versions 3
        --maximum-deltas 0
        --embed-release-notes
        -o "$feed_dir/appcast.xml"
    )
    "$generate_appcast" "${appcast_args[@]}" "$feed_dir"

    generated_build=$(xmllint --xpath \
        'string((//*[local-name()="item"]/*[local-name()="version"])[1])' \
        "$feed_dir/appcast.xml")
    generated_version=$(xmllint --xpath \
        'string((//*[local-name()="item"]/*[local-name()="shortVersionString"])[1])' \
        "$feed_dir/appcast.xml")
    generated_url=$(xmllint --xpath \
        'string((//*[local-name()="item"]/*[local-name()="enclosure"])[1]/@url)' \
        "$feed_dir/appcast.xml")
    generated_signature=$(xmllint --xpath \
        'string((//*[local-name()="item"]/*[local-name()="enclosure"])[1]/@*[local-name()="edSignature"])' \
        "$feed_dir/appcast.xml")
    generated_length=$(xmllint --xpath \
        'string((//*[local-name()="item"]/*[local-name()="enclosure"])[1]/@length)' \
        "$feed_dir/appcast.xml")
    expected_url="https://github.com/${source_repo}/releases/download/${release_version}/${release_version}.zip"
    archive_length=$(stat -f '%z' "$release_zip")

    [[ "$generated_build" == "$release_build" ]] || fail "Generated appcast has the wrong build"
    [[ "$generated_version" == "$release_version" ]] || fail "Generated appcast has the wrong version"
    [[ "$generated_url" == "$expected_url" ]] || fail "Generated appcast has the wrong download URL"
    [[ "$generated_length" == "$archive_length" ]] || fail "Generated appcast has the wrong archive length"
    [[ -n "$generated_signature" ]] || fail "Generated appcast has no EdDSA signature"
    "$sign_update" --verify --ed-key-file "$sparkle_private_key" "$release_zip" "$generated_signature"

    mkdir -p "$output_dir"
    cp "$release_zip" "$output_dir/${release_version}.zip"
    cp "$release_dmg" "$output_dir/${release_version}.dmg"
    cp "$feed_dir/appcast.xml" "$output_dir/appcast.xml"
    if [[ -n "$notes_file" ]]; then
        cp "$notes_file" "$output_dir/release-notes.txt"
    fi
    checksum_files=("${release_version}.zip" "${release_version}.dmg" appcast.xml)
    if [[ -f "$output_dir/release-notes.txt" ]]; then
        checksum_files+=(release-notes.txt)
    fi
    (cd "$output_dir" && shasum -a 256 "${checksum_files[@]}" > SHA256SUMS)
    publish_notes_file=$notes_file
fi

if ! $publish; then
    print "Prepared release artifacts in $output_dir"
    print "After review, publish them with --publish-prepared."
    exit 0
fi

releases_checkout="$work_dir/mac-releases"
git clone --quiet "$releases_repo_url" "$releases_checkout"
[[ "$(git -C "$releases_checkout" branch --show-current)" == "main" ]] || \
    fail "mac-releases default branch is not main"
cp "$output_dir/appcast.xml" "$releases_checkout/$feed_file"
git -C "$releases_checkout" diff --check
[[ -n "$(git -C "$releases_checkout" status --porcelain -- "$feed_file")" ]] || \
    fail "Generated appcast does not change the published feed"

source_commit=$(git -C "$project_root" rev-parse HEAD)
dmg_length=$(stat -f '%z' "$output_dir/${release_version}.dmg")
gh release create "$release_version" \
    "$output_dir/${release_version}.dmg#Firstlight ${release_version} (DMG)" \
    "$output_dir/${release_version}.zip#Firstlight ${release_version} (ZIP, used by the in-app updater)" \
    --repo "$source_repo" \
    --target "$source_commit" \
    --title "$release_version" \
    --notes-file "$publish_notes_file"

published_size=$(gh release view "$release_version" --repo "$source_repo" \
    --json assets --jq ".assets[] | select(.name == \"${release_version}.zip\") | .size")
[[ "$published_size" == "$archive_length" ]] || \
    fail "Published GitHub asset size does not match the signed archive"
published_dmg_size=$(gh release view "$release_version" --repo "$source_repo" \
    --json assets --jq ".assets[] | select(.name == \"${release_version}.dmg\") | .size")
[[ "$published_dmg_size" == "$dmg_length" ]] || \
    fail "Published GitHub DMG size does not match the signed image"

git -C "$releases_checkout" add -- "$feed_file"
git -C "$releases_checkout" diff --cached --check
git -C "$releases_checkout" commit -m "Release $release_version"
git -C "$releases_checkout" push origin HEAD:main

raw_feed="https://raw.githubusercontent.com/${releases_repo}/main/${feed_file}"
published_appcast="$work_dir/published-appcast.xml"
curl -fsSL --max-time 30 "${raw_feed}?release=${release_build}" -o "$published_appcast"
published_build=$(xmllint --xpath \
    'string((//*[local-name()="item"]/*[local-name()="version"])[1])' \
    "$published_appcast")
[[ "$published_build" == "$release_build" ]] || fail "Published appcast verification failed"

print "Published Firstlight $release_version (build $release_build)."
print "GitHub Release: https://github.com/${source_repo}/releases/tag/${release_version}"
print "Appcast: $feed_url"
